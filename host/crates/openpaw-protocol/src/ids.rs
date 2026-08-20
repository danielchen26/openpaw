use std::fmt;
use std::str::FromStr;

use serde::{Deserialize, Deserializer, Serialize, Serializer};
use sha2::{Digest, Sha256};

use crate::agent::AgentKind;
use crate::error::ParseIdError;
use crate::util::{hex_encode, is_lower_hex};

/// Number of hex characters kept from a sha256 digest for a derived id.
const DIGEST_CHARS: usize = 24;

/// Maximum length of the part of a session id after the `sess_` prefix,
/// dictated by `event.schema.json` (`^sess_[A-Za-z0-9._:-]{1,120}$`).
const MAX_SESSION_TAIL: usize = 120;

/// Byte inserted between the two halves of a derivation pre-image so that
/// `("a", "bc")` and `("ab", "c")` cannot collide.
const DERIVE_SEPARATOR: u8 = 0x1F;

macro_rules! string_id {
    (
        $(#[$meta:meta])*
        pub struct $name:ident($label:literal, $prefix:literal);
    ) => {
        $(#[$meta])*
        #[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
        pub struct $name(String);

        impl $name {
            /// Literal prefix every value of this type carries.
            pub const PREFIX: &'static str = $prefix;

            /// The full identifier, prefix included.
            pub fn as_str(&self) -> &str {
                &self.0
            }

            /// Consumes the identifier and returns the backing string.
            pub fn into_string(self) -> String {
                self.0
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str(&self.0)
            }
        }

        impl AsRef<str> for $name {
            fn as_ref(&self) -> &str {
                &self.0
            }
        }

        impl FromStr for $name {
            type Err = ParseIdError;

            fn from_str(text: &str) -> Result<Self, Self::Err> {
                if Self::is_valid(text) {
                    Ok($name(text.to_owned()))
                } else {
                    Err(ParseIdError::new($label, text))
                }
            }
        }

        impl Serialize for $name {
            fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
                serializer.serialize_str(&self.0)
            }
        }

        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
                let raw = String::deserialize(deserializer)?;
                raw.parse().map_err(serde::de::Error::custom)
            }
        }
    };
}

string_id! {
    /// Stable identifier for one agent session.
    ///
    /// Shaped `sess_<agent short tag>-<sanitized native id>` so that a human
    /// reading a log can tell which agent a session belongs to.
    pub struct SessionId("session id", "sess_");
}

string_id! {
    /// Content addressed event identifier.
    ///
    /// Derived from the session id and a source key (a log line offset, a hook
    /// request id, a tool call id), which makes ingestion idempotent: re-reading
    /// the same transcript produces the same ids.
    pub struct EventId("event id", "evt_");
}

string_id! {
    /// Content addressed inbox item identifier, derived from its source event.
    pub struct InboxId("inbox id", "inb_");
}

impl SessionId {
    /// Builds a session id from an agent's native session identifier.
    ///
    /// The raw value is sanitized to the schema's character class; anything
    /// else becomes `_`. Over-long values are truncated and disambiguated with
    /// a digest suffix so the result stays unique and inside the length bound.
    pub fn new(agent: AgentKind, raw: &str) -> SessionId {
        let mut tail = String::with_capacity(raw.len());
        for ch in raw.chars() {
            if matches!(ch, 'A'..='Z' | 'a'..='z' | '0'..='9' | '.' | '_' | ':' | '-') {
                tail.push(ch);
            } else {
                tail.push('_');
            }
        }
        if tail.is_empty() {
            tail.push_str("unknown");
        }

        // `sess_` + short tag + `-` already consumes 3 of the tail budget.
        let budget = MAX_SESSION_TAIL - agent.short().len() - 1;
        if tail.len() > budget {
            let digest = hex_encode(&Sha256::digest(tail.as_bytes()));
            let keep = budget - 1 - 8;
            tail.truncate(keep);
            tail.push('-');
            tail.push_str(&digest[..8]);
        }

        SessionId(format!("sess_{}-{}", agent.short(), tail))
    }

    /// The two character agent tag embedded in this id.
    pub fn agent_short(&self) -> &str {
        let rest = &self.0[Self::PREFIX.len()..];
        match rest.find('-') {
            Some(idx) => &rest[..idx],
            None => rest,
        }
    }

    /// The sanitized native identifier, without prefix or agent tag.
    pub fn tail(&self) -> &str {
        let rest = &self.0[Self::PREFIX.len()..];
        match rest.find('-') {
            Some(idx) => &rest[idx + 1..],
            None => "",
        }
    }

    fn is_valid(text: &str) -> bool {
        let Some(rest) = text.strip_prefix(Self::PREFIX) else {
            return false;
        };
        (1..=MAX_SESSION_TAIL).contains(&rest.len())
            && rest
                .chars()
                .all(|ch| matches!(ch, 'A'..='Z' | 'a'..='z' | '0'..='9' | '.' | '_' | ':' | '-'))
    }
}

impl EventId {
    /// Derives the identifier for an event from its session and a source key.
    ///
    /// `source_key` must uniquely name the origin of the event inside the
    /// session, e.g. `"transcript:42"` or `"hook:PreToolUse:call_ab12"`.
    pub fn derive(session: &SessionId, source_key: &str) -> EventId {
        EventId(format!(
            "{}{}",
            Self::PREFIX,
            derive_digest(session.as_str().as_bytes(), source_key.as_bytes())
        ))
    }

    fn is_valid(text: &str) -> bool {
        matches!(text.strip_prefix(Self::PREFIX), Some(rest) if rest.len() == DIGEST_CHARS && is_lower_hex(rest))
    }
}

impl InboxId {
    /// Derives the identifier of the inbox item projected from `event`.
    pub fn derive(event: &EventId) -> InboxId {
        let digest = hex_encode(&Sha256::digest(event.as_str().as_bytes()));
        InboxId(format!("{}{}", Self::PREFIX, &digest[..DIGEST_CHARS]))
    }

    fn is_valid(text: &str) -> bool {
        matches!(text.strip_prefix(Self::PREFIX), Some(rest) if rest.len() == DIGEST_CHARS && is_lower_hex(rest))
    }
}

fn derive_digest(left: &[u8], right: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(left);
    hasher.update([DERIVE_SEPARATOR]);
    hasher.update(right);
    let digest = hex_encode(&hasher.finalize());
    digest[..DIGEST_CHARS].to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_id_sanitizes_and_tags_the_agent() {
        let id = SessionId::new(
            AgentKind::ClaudeCode,
            "57ae0add-f501-42d6-a04d-618fc9d3bfae",
        );
        assert_eq!(id.as_str(), "sess_cc-57ae0add-f501-42d6-a04d-618fc9d3bfae");
        assert_eq!(id.agent_short(), "cc");

        let path = SessionId::new(AgentKind::OpenCode, "/Users/dev/src/open paw!");
        assert_eq!(path.as_str(), "sess_oc-_Users_dev_src_open_paw_");
        assert!(path.as_str().parse::<SessionId>().is_ok());
    }

    #[test]
    fn session_id_stays_inside_the_schema_length_bound() {
        let raw = "x".repeat(400);
        let id = SessionId::new(AgentKind::Codex, &raw);
        assert!(id.as_str().len() <= "sess_".len() + MAX_SESSION_TAIL);
        assert!(id.as_str().parse::<SessionId>().is_ok());
        // Distinct long inputs stay distinct thanks to the digest suffix.
        let other = SessionId::new(AgentKind::Codex, &format!("{raw}y"));
        assert_ne!(id, other);
    }

    #[test]
    fn empty_raw_session_id_is_replaced() {
        assert_eq!(
            SessionId::new(AgentKind::Generic, "").as_str(),
            "sess_gn-unknown"
        );
    }

    #[test]
    fn session_id_rejects_bad_input() {
        assert!("cc-1".parse::<SessionId>().is_err());
        assert!("sess_".parse::<SessionId>().is_err());
        assert!("sess_a/b".parse::<SessionId>().is_err());
        assert!("sess_ok.1:2-3_4".parse::<SessionId>().is_ok());
    }

    #[test]
    fn ids_reject_wrong_shape() {
        assert!("evt_zzzz".parse::<EventId>().is_err());
        assert!("inb_0123456789abcdef01234567".parse::<InboxId>().is_ok());
        assert!("evt_0123456789ABCDEF01234567".parse::<EventId>().is_err());
    }
}
