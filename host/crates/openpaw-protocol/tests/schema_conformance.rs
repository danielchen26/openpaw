//! Validates generated samples against the JSON schemas that define the wire
//! format. This is the test that keeps the Rust types honest: the schemas are
//! the contract, not the structs.

mod common;

use common::{repo_root, sample_event, sample_inbox_item};
use jsonschema::{Registry, Resource, Validator};
use openpaw_protocol::{Body, EventType, InboxItem, PlanStepStatus};
use serde_json::Value;

const EVENT_SCHEMA_URI: &str = "https://openpaw.dev/schema/v1/event.schema.json";

fn load(name: &str) -> Value {
    let path = repo_root().join("protocol/json-schema").join(name);
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("cannot read {}: {error}", path.display()));
    serde_json::from_str(&text)
        .unwrap_or_else(|error| panic!("{} is not valid JSON: {error}", path.display()))
}

/// The inbox schema `$ref`s the event schema by relative URI, so the event
/// schema is registered under its `$id` before compiling.
fn validators() -> (Validator, Validator) {
    let event_schema = load("event.schema.json");
    let inbox_schema = load("inbox-item.schema.json");

    let registry = Registry::new()
        .add(
            EVENT_SCHEMA_URI,
            Resource::from_contents(event_schema.clone()),
        )
        .expect("event schema is a valid resource")
        .prepare()
        .expect("registry prepares");

    let event = jsonschema::options()
        .with_registry(&registry)
        .build(&event_schema)
        .expect("event.schema.json compiles");
    let inbox = jsonschema::options()
        .with_registry(&registry)
        .build(&inbox_schema)
        .expect("inbox-item.schema.json compiles");
    (event, inbox)
}

fn assert_valid(validator: &Validator, label: &str, instance: &Value) {
    let errors: Vec<String> = validator
        .iter_errors(instance)
        .map(|error| format!("{} at {}", error, error.instance_path()))
        .collect();
    assert!(
        errors.is_empty(),
        "{label} does not satisfy its schema:\n  {}\ninstance: {}",
        errors.join("\n  "),
        serde_json::to_string_pretty(instance).unwrap()
    );
}

#[test]
fn provider_and_repo_import_contracts_are_sanitized_and_schema_valid() {
    let provider_schema = load("provider.schema.json");
    let repo_schema = load("repo-import.schema.json");
    let provider_validator = jsonschema::options()
        .build(&provider_schema)
        .expect("provider schema compiles");
    let repo_validator = jsonschema::options()
        .build(&repo_schema)
        .expect("repo import schema compiles");

    let status = serde_json::to_value(openpaw_protocol::ProviderStatus {
        id: openpaw_protocol::ProviderId::Github,
        display_name: "GitHub".to_owned(),
        state: openpaw_protocol::ProviderConnectionState::Connected,
        account_label: Some("octocat".to_owned()),
        scopes: vec!["repo:read".to_owned()],
        repo_listing_supported: true,
    })
    .unwrap();
    assert_valid(&provider_validator, "provider status", &status);
    assert_contract_has_no_secret_or_path_keys(&status);

    let import = serde_json::to_value(openpaw_protocol::RepoImportRequest {
        provider: openpaw_protocol::ProviderId::Github,
        repo_id: "repo_123".to_owned(),
        requested_name: Some("openpaw".to_owned()),
    })
    .unwrap();
    assert_valid(&repo_validator, "repo import request", &import);
    assert_contract_has_no_secret_or_path_keys(&import);

    let progress = serde_json::to_value(openpaw_protocol::RepoImportProgress {
        id: "imp_123".to_owned(),
        state: openpaw_protocol::RepoImportState::Cloning,
        repo_name: "openpaw".to_owned(),
        destination_name: "openpaw-2".to_owned(),
        percent: Some(42),
        message: Some("cloning".to_owned()),
        source_url_redacted: Some(openpaw_protocol::redact_url_credentials(
            "https://user:token@example.com/org/repo.git",
        )),
    })
    .unwrap();
    assert_valid(&repo_validator, "repo import progress", &progress);
    assert_contract_has_no_secret_or_path_keys(&progress);
    assert_eq!(
        progress["source_url_redacted"],
        "https://<redacted>@example.com/org/repo.git"
    );
}

#[test]
fn repo_import_contract_rejects_caller_destination_paths_and_secret_maps() {
    let repo_schema = load("repo-import.schema.json");
    let repo_validator = jsonschema::options()
        .build(&repo_schema)
        .expect("repo import schema compiles");
    let bad = serde_json::json!({"provider":"github","repo_id":"r","destination_path":"/tmp/r"});
    assert!(!repo_validator.is_valid(&bad));
    assert!(serde_json::from_value::<openpaw_protocol::RepoImportRequest>(bad).is_err());
    let bad_progress = serde_json::json!({"id":"i","state":"cloning","repo_name":"r","destination_name":"r","env":{"GIT_ASKPASS":"/tmp/askpass"}});
    assert!(!repo_validator.is_valid(&bad_progress));
}

fn assert_contract_has_no_secret_or_path_keys(value: &Value) {
    const FORBIDDEN: &[&str] = &[
        "token",
        "authorization",
        "authorization_header",
        "credential_path",
        "env",
        "destination_path",
    ];
    match value {
        Value::Object(map) => {
            for (key, value) in map {
                assert!(
                    !FORBIDDEN.contains(&key.as_str()),
                    "forbidden key {key} in {map:?}"
                );
                assert_contract_has_no_secret_or_path_keys(value);
            }
        }
        Value::Array(values) => values
            .iter()
            .for_each(assert_contract_has_no_secret_or_path_keys),
        _ => {}
    }
}

#[test]
fn every_event_type_validates_against_the_event_schema() {
    let (event_validator, _) = validators();
    for kind in EventType::ALL {
        let instance = serde_json::to_value(sample_event(*kind)).unwrap();
        assert_valid(&event_validator, kind.as_str(), &instance);
    }
}

#[test]
fn a_minimal_event_without_context_validates() {
    let (event_validator, _) = validators();
    let mut instance = serde_json::to_value(sample_event(EventType::AgentWorking)).unwrap();
    instance["cwd"] = Value::Null;
    instance["git_branch"] = Value::Null;
    instance["multiplexer_target"] = Value::Null;
    assert_valid(&event_validator, "agent.working (no context)", &instance);
}

#[test]
fn every_inbox_category_validates_against_the_inbox_schema() {
    let (_, inbox_validator) = validators();

    let mut seen = Vec::new();
    for kind in EventType::ALL {
        if let Some(item) = InboxItem::from_event(&sample_event(*kind)) {
            let instance = serde_json::to_value(&item).unwrap();
            assert_valid(&inbox_validator, kind.as_str(), &instance);
            seen.push(item.category);
        }
    }
    assert!(
        seen.contains(&openpaw_protocol::InboxCategory::Permission),
        "the permission projection must be exercised, saw {seen:?}"
    );

    let permission = serde_json::to_value(sample_inbox_item()).unwrap();
    assert_valid(&inbox_validator, "permission inbox item", &permission);
}

#[test]
fn the_schema_rejects_events_the_types_cannot_produce() {
    let (event_validator, _) = validators();
    let good = serde_json::to_value(sample_event(EventType::PermissionRequested)).unwrap();
    assert!(event_validator.is_valid(&good));

    // Wrong version constant.
    let mut wrong_version = good.clone();
    wrong_version["version"] = Value::String("2".to_owned());
    assert!(!event_validator.is_valid(&wrong_version));

    // Malformed event id.
    let mut wrong_id = good.clone();
    wrong_id["event_id"] = Value::String("evt_short".to_owned());
    assert!(!event_validator.is_valid(&wrong_id));

    // Undeclared top level key: the schema sets additionalProperties false.
    let mut extra = good.clone();
    extra["surprise"] = Value::Bool(true);
    assert!(!event_validator.is_valid(&extra));

    // permission.requested requires at least one action.
    let mut no_actions = good;
    no_actions["payload"]["actions"] = Value::Array(Vec::new());
    assert!(!event_validator.is_valid(&no_actions));
}

#[test]
fn enum_wire_strings_match_the_schema_enumerations() {
    let schema = load("event.schema.json");

    let declared: Vec<&str> = schema["$defs"]["eventType"]["enum"]
        .as_array()
        .unwrap()
        .iter()
        .map(|value| value.as_str().unwrap())
        .collect();
    let ours: Vec<&str> = EventType::ALL.iter().map(|kind| kind.as_str()).collect();
    assert_eq!(ours, declared, "EventType must mirror the schema, in order");

    let declared_agents: Vec<&str> = schema["$defs"]["agentKind"]["enum"]
        .as_array()
        .unwrap()
        .iter()
        .map(|value| value.as_str().unwrap())
        .collect();
    let our_agents: Vec<&str> = openpaw_protocol::AgentKind::ALL
        .iter()
        .map(|agent| agent.as_str())
        .collect();
    assert_eq!(our_agents, declared_agents);

    let declared_actions: Vec<&str> = schema["$defs"]["action"]["enum"]
        .as_array()
        .unwrap()
        .iter()
        .map(|value| value.as_str().unwrap())
        .collect();
    let our_actions: Vec<&str> = openpaw_protocol::ActionId::ALL
        .iter()
        .map(|action| action.as_str())
        .collect();
    assert_eq!(our_actions, declared_actions);

    let declared_classes: Vec<&str> = schema["$defs"]["riskClass"]["enum"]
        .as_array()
        .unwrap()
        .iter()
        .map(|value| value.as_str().unwrap())
        .collect();
    let our_classes: Vec<&str> = openpaw_protocol::RiskClass::ALL
        .iter()
        .map(|class| class.as_str())
        .collect();
    assert_eq!(our_classes, declared_classes);

    let inbox = load("inbox-item.schema.json");
    let declared_categories: Vec<&str> = inbox["properties"]["category"]["enum"]
        .as_array()
        .unwrap()
        .iter()
        .map(|value| value.as_str().unwrap())
        .collect();
    let our_categories: Vec<&str> = openpaw_protocol::InboxCategory::ALL
        .iter()
        .map(|category| category.as_str())
        .collect();
    assert_eq!(our_categories, declared_categories);

    let declared_statuses: Vec<&str> = inbox["properties"]["status"]["enum"]
        .as_array()
        .unwrap()
        .iter()
        .map(|value| value.as_str().unwrap())
        .collect();
    let our_statuses: Vec<&str> = openpaw_protocol::InboxStatus::ALL
        .iter()
        .map(|status| status.as_str())
        .collect();
    assert_eq!(our_statuses, declared_statuses);
}

#[test]
fn plan_step_statuses_serialize_to_the_documented_strings() {
    // The plan step vocabulary is not in the schema, so pin it here: the Swift
    // mirror and the UI both switch on these exact strings.
    let statuses: Vec<&str> = PlanStepStatus::ALL
        .iter()
        .map(|status| status.as_str())
        .collect();
    assert_eq!(
        statuses,
        vec!["pending", "in_progress", "completed", "cancelled"]
    );

    let value = serde_json::to_value(sample_event(EventType::PlanCreated)).unwrap();
    let steps = value["payload"]["steps"].as_array().unwrap();
    assert_eq!(steps[0]["status"], "completed");
    assert_eq!(steps[1]["status"], "in_progress");
    assert_eq!(steps[2]["status"], "pending");
    assert_eq!(steps[3]["status"], "cancelled");
}

#[test]
fn body_kind_agrees_with_the_serialized_type_for_every_variant() {
    for kind in EventType::ALL {
        let event = sample_event(*kind);
        let body: &Body = &event.body;
        assert_eq!(body.kind(), *kind);
        assert_eq!(
            serde_json::to_value(&event).unwrap()["type"],
            Value::String(kind.as_str().to_owned())
        );
    }
}
