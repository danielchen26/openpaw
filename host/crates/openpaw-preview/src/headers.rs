//! Header hygiene for the loopback preview proxy.
//!
//! Two jobs live here, both pure so they can be unit-tested without sockets:
//!
//! 1. Hop-by-hop stripping. A reverse proxy must not relay connection-scoped
//!    headers, otherwise upstream framing leaks into the downstream connection.
//! 2. Origin rewriting. The upstream dev server believes it is reachable at
//!    `127.0.0.1:<port>/`, but the phone reaches it at `<mount_prefix>/`. Any
//!    header that carries a URL or a cookie scope has to be translated or
//!    redirects and cookies escape the mount.

use http::header::{CONNECTION, HOST, HeaderMap, HeaderName, HeaderValue};

/// Headers that describe a single hop and must never be forwarded.
const HOP_BY_HOP: &[&str] = &[
    "connection",
    "keep-alive",
    "te",
    "trailer",
    "trailers",
    "transfer-encoding",
    "upgrade",
];

/// True when `name` is hop-by-hop by definition (RFC 9110 §7.6.1) or is a
/// `proxy-*` header, which is addressed to us rather than to the upstream.
pub(crate) fn is_hop_by_hop(name: &HeaderName) -> bool {
    let name = name.as_str();
    HOP_BY_HOP.contains(&name) || name.starts_with("proxy-")
}

/// Connection-header tokens name *additional* per-hop headers. `Connection:
/// close, x-custom` means `x-custom` is hop-scoped too.
fn connection_tokens(headers: &HeaderMap) -> Vec<String> {
    headers
        .get_all(CONNECTION)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .flat_map(|v| v.split(','))
        .map(|t| t.trim().to_ascii_lowercase())
        .filter(|t| !t.is_empty() && t != "close" && t != "keep-alive" && t != "upgrade")
        .collect()
}

/// Copy request headers the upstream is allowed to see.
///
/// Everything end-to-end (`accept`, `range`, `if-none-match`, `cookie`,
/// `content-type`, …) is passed through byte-for-byte; only per-hop headers and
/// `host` are dropped. The caller sets `host` to the loopback authority.
pub(crate) fn copy_request_headers(src: &HeaderMap, dst: &mut HeaderMap) {
    let tokens = connection_tokens(src);
    for (name, value) in src.iter() {
        if is_hop_by_hop(name) || name == HOST {
            continue;
        }
        if tokens.iter().any(|t| t == name.as_str()) {
            continue;
        }
        dst.append(name.clone(), value.clone());
    }
}

/// Copy response headers, rewriting anything that leaks the upstream origin.
pub(crate) fn copy_response_headers(
    src: &HeaderMap,
    dst: &mut HeaderMap,
    port: u16,
    mount_prefix: &str,
) {
    let tokens = connection_tokens(src);
    let prefix = normalize_prefix(mount_prefix);
    for (name, value) in src.iter() {
        if is_hop_by_hop(name) {
            continue;
        }
        if tokens.iter().any(|t| t == name.as_str()) {
            continue;
        }
        let rewritten = match name.as_str() {
            "location" | "content-location" => value
                .to_str()
                .ok()
                .and_then(|v| rewrite_location(v, port, &prefix))
                .and_then(|v| HeaderValue::from_str(&v).ok()),
            "set-cookie" => value
                .to_str()
                .ok()
                .map(|v| rewrite_set_cookie(v, &prefix))
                .and_then(|v| HeaderValue::from_str(&v).ok()),
            _ => None,
        };
        dst.append(name.clone(), rewritten.unwrap_or_else(|| value.clone()));
    }
}

/// Drop a trailing slash so `prefix + "/x"` never doubles up.
pub(crate) fn normalize_prefix(mount_prefix: &str) -> String {
    let trimmed = mount_prefix.trim_end_matches('/');
    if trimmed.is_empty() {
        String::new()
    } else if trimmed.starts_with('/') {
        trimmed.to_owned()
    } else {
        format!("/{trimmed}")
    }
}

/// Translate a redirect target into the proxy's address space.
///
/// * absolute URL pointing at the proxied loopback port -> mounted path
/// * root-relative path -> mounted path
/// * anything else (external absolute URL, relative path) -> unchanged, because
///   a relative redirect already resolves against the mounted request path and
///   an external host is not ours to rewrite.
pub(crate) fn rewrite_location(value: &str, port: u16, prefix: &str) -> Option<String> {
    let value = value.trim();
    if let Some(rest) = strip_local_origin(value, port) {
        let rest = if rest.is_empty() { "/" } else { rest };
        return Some(format!("{prefix}{rest}"));
    }
    // A protocol-relative URL (`//host/x`) points at another origin.
    if value.starts_with('/') && !value.starts_with("//") {
        return Some(format!("{prefix}{value}"));
    }
    None
}

/// If `value` is an absolute URL whose authority is the loopback port we are
/// proxying, return the path-and-beyond remainder.
fn strip_local_origin(value: &str, port: u16) -> Option<&str> {
    let rest = value
        .strip_prefix("http://")
        .or_else(|| value.strip_prefix("https://"))?;
    let (authority, tail) = match rest.find(['/', '?', '#']) {
        Some(idx) => rest.split_at(idx),
        None => (rest, ""),
    };
    let authority = authority.rsplit('@').next().unwrap_or(authority);
    let matches = ["127.0.0.1", "localhost", "[::1]", "0.0.0.0"]
        .iter()
        .any(|host| authority.eq_ignore_ascii_case(&format!("{host}:{port}")));
    if matches { Some(tail) } else { None }
}

/// Re-scope a cookie so it cannot escape the preview mount.
///
/// `Domain` is removed outright: the upstream's notion of a domain is
/// meaningless to the phone, and leaving it would make the browser reject the
/// cookie. `Path` is prefixed with the mount, and a `Path` is added when the
/// upstream omitted one so the default (the request directory) cannot widen.
pub(crate) fn rewrite_set_cookie(value: &str, prefix: &str) -> String {
    let mut out: Vec<String> = Vec::new();
    let mut saw_path = false;
    for (idx, part) in value.split(';').enumerate() {
        let trimmed = part.trim();
        if idx == 0 {
            out.push(trimmed.to_owned());
            continue;
        }
        if trimmed.is_empty() {
            continue;
        }
        let (key, rest) = match trimmed.split_once('=') {
            Some((k, v)) => (k.trim(), Some(v.trim())),
            None => (trimmed, None),
        };
        if key.eq_ignore_ascii_case("domain") {
            continue;
        }
        if key.eq_ignore_ascii_case("path") {
            saw_path = true;
            let path = rest.unwrap_or("/");
            let path = if path.starts_with('/') {
                path.to_owned()
            } else {
                format!("/{path}")
            };
            let mounted = if path == "/" {
                format!("{prefix}/")
            } else {
                format!("{prefix}{path}")
            };
            out.push(format!("Path={mounted}"));
            continue;
        }
        out.push(trimmed.to_owned());
    }
    if !saw_path && !prefix.is_empty() {
        out.push(format!("Path={prefix}/"));
    }
    out.join("; ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hop_by_hop_headers_are_recognized() {
        for name in [
            "connection",
            "keep-alive",
            "te",
            "trailer",
            "transfer-encoding",
            "upgrade",
            "proxy-authorization",
            "proxy-connection",
        ] {
            let header = HeaderName::from_bytes(name.as_bytes()).unwrap();
            assert!(is_hop_by_hop(&header), "{name} should be hop-by-hop");
        }
        for name in ["accept", "range", "if-none-match", "cookie", "content-type"] {
            let header = HeaderName::from_bytes(name.as_bytes()).unwrap();
            assert!(!is_hop_by_hop(&header), "{name} is end-to-end");
        }
    }

    #[test]
    fn connection_tokens_are_treated_as_hop_scoped() {
        let mut src = HeaderMap::new();
        src.insert(CONNECTION, HeaderValue::from_static("close, X-Hop-Only"));
        src.insert("x-hop-only", HeaderValue::from_static("secret"));
        src.insert("accept", HeaderValue::from_static("text/html"));
        let mut dst = HeaderMap::new();
        copy_request_headers(&src, &mut dst);
        assert!(dst.get("x-hop-only").is_none());
        assert_eq!(dst.get("accept").unwrap(), "text/html");
    }

    #[test]
    fn absolute_upstream_location_is_mounted() {
        assert_eq!(
            rewrite_location("http://127.0.0.1:5173/x", 5173, "/v1/preview/5173"),
            Some("/v1/preview/5173/x".to_owned())
        );
        assert_eq!(
            rewrite_location("http://localhost:5173/a?b=1#c", 5173, "/v1/preview/5173"),
            Some("/v1/preview/5173/a?b=1#c".to_owned())
        );
        assert_eq!(
            rewrite_location("http://127.0.0.1:5173", 5173, "/v1/preview/5173"),
            Some("/v1/preview/5173/".to_owned())
        );
    }

    #[test]
    fn root_relative_location_is_mounted_and_foreign_origins_are_left_alone() {
        assert_eq!(
            rewrite_location("/login", 5173, "/v1/preview/5173"),
            Some("/v1/preview/5173/login".to_owned())
        );
        assert_eq!(rewrite_location("../up", 5173, "/v1/preview/5173"), None);
        assert_eq!(
            rewrite_location("https://example.com/x", 5173, "/v1/preview/5173"),
            None
        );
        // Another loopback port is a different upstream; not ours to rewrite.
        assert_eq!(
            rewrite_location("http://127.0.0.1:9999/x", 5173, "/v1/preview/5173"),
            None
        );
        assert_eq!(rewrite_location("//evil.example/x", 5173, "/p"), None);
    }

    #[test]
    fn set_cookie_domain_is_dropped_and_path_is_mounted() {
        assert_eq!(
            rewrite_set_cookie(
                "sid=abc; Domain=localhost; Path=/; HttpOnly",
                "/v1/preview/5173"
            ),
            "sid=abc; Path=/v1/preview/5173/; HttpOnly"
        );
        assert_eq!(
            rewrite_set_cookie("sid=abc; Path=/app", "/v1/preview/5173"),
            "sid=abc; Path=/v1/preview/5173/app"
        );
        assert_eq!(
            rewrite_set_cookie("sid=abc", "/v1/preview/5173"),
            "sid=abc; Path=/v1/preview/5173/"
        );
    }

    #[test]
    fn prefix_normalization_is_idempotent() {
        assert_eq!(normalize_prefix("/v1/preview/5173/"), "/v1/preview/5173");
        assert_eq!(normalize_prefix("v1/preview/5173"), "/v1/preview/5173");
        assert_eq!(normalize_prefix("/"), "");
    }
}
