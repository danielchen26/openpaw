# OpenPaw notification foundation

This slice defines a simulator-testable notification foundation in `packages/swift-openpaw-notifications` only. It intentionally does not integrate with the iOS app, APNs, UserNotifications, ActivityKit, Watch frameworks, host protocol, or Xcode project files.

## Security boundary

`NotificationHint` is a minimized, stable-schema envelope for local presentation and navigation. Schema version `1` is encoded as `schema_version`, and all host, device, session, inbox, notification, and nonce identifiers are opaque strings.

The hint is allowed to contain only:

- schema version
- notification ID
- host/device/session/inbox IDs
- category
- risk
- created and expiry timestamps
- nonce
- redacted title
- navigation action intent

It must never contain `action_token`, `command`, `credentials`, `raw_detail`, `secret`, or equivalent authorization material. The validator rejects these forbidden top-level payload fields before model decode. Titles are sanitized and capped by both UTF-8 bytes and Unicode scalars so notification UI cannot expose raw detail or secrets.

## Action intent policy

Notification action intents are navigation-only by default:

- `openInbox`
- `openDetail(inboxID:)`

A decision representation may use `decisionReview(inboxID:decisionID:)`, but this is still not an approval, denial, stop, or authorization. It requires the foreground app to authenticate and refresh the full inbox item before any consequential operation. The package exposes this as `requiresForegroundAuthenticatedRefresh == true` and `carriesAuthorizationMaterial == false`.

## Replay and expiry gate

`NotificationReplayExpiryGate` is deterministic and in-memory for this foundation slice. It is keyed by `notificationID | nonce` and enforces:

- maximum payload size
- future clock skew limit
- maximum age
- expiry timestamp
- duplicate rejection
- bounded replay memory with FIFO eviction

This gate is suitable for simulator tests and for future app integration as a local preflight. Production delivery authenticity is out of scope for this slice and must be added before remote push claims.

## Local presentation mapping

`LocalNotificationPresentationMapper` maps a hint to safe primitives:

- safe title from the redacted capped title
- safe body
- category identifier `openpaw.<category>`
- thread identifier derived only from opaque host/session/inbox IDs

For consequential or decision-review notifications, the body truthfully says: `Open OpenPaw to review`.
