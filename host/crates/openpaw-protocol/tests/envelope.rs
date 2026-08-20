//! Envelope wire format: key set, key order, RFC 3339 timestamps, round-trip.

mod common;

use common::{sample_event, session, timestamp};
use openpaw_protocol::{AgentKind, Body, Event, EventId, EventType, PROTOCOL_VERSION, SessionId};
use serde_json::Value;

/// Keys the schema declares on the envelope. Anything else is a break, because
/// `event.schema.json` sets `additionalProperties: false`.
const ENVELOPE_KEYS: &[&str] = &[
    "version",
    "event_id",
    "session_id",
    "agent",
    "seq",
    "timestamp",
    "cwd",
    "git_branch",
    "multiplexer_target",
    "type",
    "payload",
];

#[test]
fn envelope_has_exactly_the_schema_keys_in_the_agreed_order() {
    let json = serde_json::to_string(&sample_event(EventType::ToolStarted)).unwrap();

    // Key order is part of the cross-language contract, so assert on the raw
    // text rather than on a (sorted) serde_json::Map.
    let mut cursor = 0usize;
    for key in ENVELOPE_KEYS {
        let needle = format!("\"{key}\":");
        let found = json[cursor..]
            .find(&needle)
            .unwrap_or_else(|| panic!("missing key {key} after byte {cursor} in {json}"));
        cursor += found + needle.len();
    }

    let value: Value = serde_json::from_str(&json).unwrap();
    let object = value.as_object().unwrap();
    assert_eq!(
        object.len(),
        ENVELOPE_KEYS.len(),
        "unexpected keys: {object:?}"
    );
    for key in ENVELOPE_KEYS {
        assert!(object.contains_key(*key), "missing {key}");
    }
}

#[test]
fn context_keys_are_emitted_as_null_when_absent() {
    let event = Event::new(
        &session(),
        AgentKind::Codex,
        "transcript:1",
        timestamp(),
        Body::AgentWorking(Default::default()),
    );
    let value = serde_json::to_value(&event).unwrap();
    for key in ["cwd", "git_branch", "multiplexer_target"] {
        assert_eq!(value[key], Value::Null, "{key} must be present and null");
    }
    assert_eq!(value["version"], PROTOCOL_VERSION);
    assert_eq!(value["seq"], 0);
}

#[test]
fn timestamps_serialize_as_rfc3339() {
    let value = serde_json::to_value(sample_event(EventType::AgentStarted)).unwrap();
    assert_eq!(value["timestamp"], "2026-08-20T14:30:00Z");

    let permission = serde_json::to_value(sample_event(EventType::PermissionRequested)).unwrap();
    assert_eq!(permission["payload"]["expires_at"], "2026-08-20T14:35:00Z");
}

#[test]
fn payload_option_fields_are_omitted_when_none_and_vecs_are_always_emitted() {
    let value = serde_json::to_value(sample_event(EventType::FileRead)).unwrap();
    let payload = value["payload"].as_object().unwrap();
    assert_eq!(payload.keys().collect::<Vec<_>>(), vec!["path"]);

    let tool = serde_json::to_value(sample_event(EventType::ToolStarted)).unwrap();
    assert!(tool["payload"]["paths"].is_array());

    let question = serde_json::to_value(sample_event(EventType::QuestionRequested)).unwrap();
    assert!(question["payload"]["choices"].is_array());
}

#[test]
fn every_event_type_round_trips_byte_for_byte() {
    assert_eq!(
        EventType::ALL.len(),
        23,
        "the schema declares 23 event types"
    );
    for kind in EventType::ALL {
        let event = sample_event(*kind);
        let encoded = serde_json::to_string(&event).unwrap();
        let decoded: Event = serde_json::from_str(&encoded)
            .unwrap_or_else(|error| panic!("{kind} failed to decode: {error}\n{encoded}"));
        assert_eq!(decoded, event, "{kind} did not survive a round trip");
        assert_eq!(decoded.kind(), *kind);
        assert_eq!(serde_json::to_string(&decoded).unwrap(), encoded);
    }
}

#[test]
fn the_type_tag_matches_the_event_type_string() {
    for kind in EventType::ALL {
        let value = serde_json::to_value(sample_event(*kind)).unwrap();
        assert_eq!(value["type"], kind.as_str());
        assert!(
            value["payload"].is_object(),
            "{kind} payload must be an object"
        );
    }
}

#[test]
fn unknown_type_tags_are_rejected() {
    let mut value = serde_json::to_value(sample_event(EventType::AgentStarted)).unwrap();
    value["type"] = Value::String("agent.exploded".to_owned());
    assert!(serde_json::from_value::<Event>(value).is_err());
}

#[test]
fn identifiers_are_validated_on_the_way_in() {
    let mut value = serde_json::to_value(sample_event(EventType::AgentStarted)).unwrap();
    value["event_id"] = Value::String("evt_not-hex".to_owned());
    let error = serde_json::from_value::<Event>(value)
        .unwrap_err()
        .to_string();
    assert!(error.contains("event id"), "unexpected error: {error}");
}

#[test]
fn event_type_parses_back_from_its_wire_string() {
    for kind in EventType::ALL {
        assert_eq!(kind.as_str().parse::<EventType>().unwrap(), *kind);
    }
    assert!("agent.exploded".parse::<EventType>().is_err());
}

#[test]
fn event_id_derivation_is_stable_and_session_scoped() {
    let session = session();
    let first = EventId::derive(&session, "transcript:42");
    let second = EventId::derive(&session, "transcript:42");
    assert_eq!(first, second, "same inputs must produce the same id");
    assert_eq!(first.as_str().len(), "evt_".len() + 24);

    let other_key = EventId::derive(&session, "transcript:43");
    assert_ne!(first, other_key, "a different source key must differ");

    let other_session =
        EventId::derive(&SessionId::new(AgentKind::Codex, "other"), "transcript:42");
    assert_ne!(first, other_session, "a different session must differ");

    // The separator byte prevents (session, key) concatenation collisions.
    let left = SessionId::new(AgentKind::Generic, "ab");
    let right = SessionId::new(AgentKind::Generic, "a");
    assert_ne!(
        EventId::derive(&left, "c"),
        EventId::derive(&right, "bc"),
        "concatenation must not collide"
    );
}

#[test]
fn seq_and_context_builders_do_not_disturb_the_id() {
    let base = Event::new(
        &session(),
        AgentKind::OpenCode,
        "part:prt_a4",
        timestamp(),
        Body::AgentWorking(Default::default()),
    );
    let id = base.event_id.clone();
    let decorated = base
        .with_seq(19)
        .with_context(Some("/tmp".to_owned()), Some("main".to_owned()));
    assert_eq!(decorated.event_id, id);
    assert_eq!(decorated.seq, 19);
    assert_eq!(decorated.cwd.as_deref(), Some("/tmp"));
}
