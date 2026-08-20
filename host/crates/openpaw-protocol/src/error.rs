use std::fmt;

/// A textual identifier did not match the wire pattern for its kind.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("invalid {kind}: {value:?}")]
pub struct ParseIdError {
    /// Human readable identifier kind, e.g. `"session id"`.
    pub kind: &'static str,
    /// The rejected input.
    pub value: String,
}

impl ParseIdError {
    pub(crate) fn new(kind: &'static str, value: &str) -> Self {
        Self {
            kind,
            value: value.to_owned(),
        }
    }
}

/// A string did not correspond to any variant of a wire enum.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParseEnumError {
    /// Name of the Rust enum that rejected the value.
    pub kind: &'static str,
    /// The rejected input.
    pub value: String,
}

impl ParseEnumError {
    pub(crate) fn new(kind: &'static str, value: &str) -> Self {
        Self {
            kind,
            value: value.to_owned(),
        }
    }
}

impl fmt::Display for ParseEnumError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "unknown {} value: {:?}", self.kind, self.value)
    }
}

impl std::error::Error for ParseEnumError {}
