import Foundation
import Testing
@testable import OpenPawNotifications

@Suite("Notification hint security foundation")
struct OpenPawNotificationsTests {
    @Test func goldenEncodingShapeIsStableAndMinimal() throws {
        let hint = try NotificationHint(
            id: "notif-1", hostID: "host-opaque", deviceID: "device-opaque", sessionID: "session-opaque", inboxID: "inbox-opaque",
            category: .decisionRequired, risk: .high, createdAt: 1_700_000_000, expiresAt: 1_700_000_300,
            nonce: "nonce-1", title: "Approve deploy?", actionIntent: .openDetail(inboxID: "inbox-opaque")
        )
        let data = try JSONEncoder.openPawNotifications.encode(hint)
        #expect(String(decoding: data, as: UTF8.self) == "{\"action_intent\":{\"inbox_id\":\"inbox-opaque\",\"type\":\"open_detail\"},\"category\":\"decision_required\",\"created_at\":1700000000,\"device_id\":\"device-opaque\",\"expires_at\":1700000300,\"host_id\":\"host-opaque\",\"id\":\"notif-1\",\"inbox_id\":\"inbox-opaque\",\"nonce\":\"nonce-1\",\"risk\":\"high\",\"schema_version\":1,\"session_id\":\"session-opaque\",\"title\":\"Approve deploy?\"}")
        let decoded = try JSONDecoder().decode(NotificationHint.self, from: data)
        #expect(decoded == hint)
    }

    @Test func rejectsForbiddenFieldsAndMalformedPayloads() throws {
        let forbidden = ["action_token", "command", "credentials", "raw_detail", "secret"]
        for key in forbidden {
            let json = "{\"schema_version\":1,\"id\":\"n\",\"host_id\":\"h\",\"device_id\":\"d\",\"session_id\":\"s\",\"inbox_id\":\"i\",\"category\":\"message\",\"risk\":\"low\",\"created_at\":10,\"expires_at\":20,\"nonce\":\"x\",\"title\":\"ok\",\"action_intent\":{\"type\":\"open_inbox\"},\"\(key)\":\"NOPE\"}"
            var gate = NotificationReplayExpiryGate(maxPayloadBytes: 4096)
            #expect(throws: NotificationPayloadError.forbiddenField(key)) { try NotificationPayloadValidator.decode(Data(json.utf8), now: 10, gate: &gate) }
        }
        var gate = NotificationReplayExpiryGate(maxPayloadBytes: 4096)
        #expect(throws: NotificationPayloadError.malformed) { try NotificationPayloadValidator.decode(Data("[]".utf8), now: 10, gate: &gate) }
    }

    @Test func redactsAndTruncatesSafeTitles() throws {
        let title = try SafeNotificationTitle("Deploy 🚀🚀🚀🚀🚀🚀🚀🚀", maxUTF8Bytes: 24, maxScalars: 8)
        #expect(title.value.utf8.count <= 24)
        #expect(title.value.unicodeScalars.count <= 8)
    }

    @Test func gateRejectsExpiredFutureSkewStaleOversizedDuplicateAndCapacityPressure() throws {
        var gate = NotificationReplayExpiryGate(capacity: 2, maxPayloadBytes: 512, maxClockSkewSeconds: 30, maxAgeSeconds: 120)
        let fresh = validPayload(id: "a", created: 100, expires: 150, nonce: "na")
        try gate.accept(fresh, payloadByteCount: 100, now: 100)
        #expect(throws: NotificationPayloadError.duplicate) { try gate.accept(fresh, payloadByteCount: 100, now: 101) }
        #expect(throws: NotificationPayloadError.expired) { try gate.accept(validPayload(id: "b", created: 100, expires: 150, nonce: "nb"), payloadByteCount: 100, now: 151) }
        #expect(throws: NotificationPayloadError.futureSkew) { try gate.accept(validPayload(id: "c", created: 200, expires: 250, nonce: "nc"), payloadByteCount: 100, now: 100) }
        #expect(throws: NotificationPayloadError.stale) { try gate.accept(validPayload(id: "d", created: 1, expires: 121, nonce: "nd"), payloadByteCount: 100, now: 150) }
        #expect(throws: NotificationPayloadError.oversized) { try gate.accept(validPayload(id: "e", created: 100, expires: 150, nonce: "ne"), payloadByteCount: 513, now: 100) }
        try gate.accept(validPayload(id: "b", created: 100, expires: 150, nonce: "nb"), payloadByteCount: 100, now: 100)
        #expect(throws: NotificationPayloadError.replayStorePressure) { try gate.accept(validPayload(id: "c", created: 100, expires: 150, nonce: "nc"), payloadByteCount: 100, now: 100) }
        #expect(throws: NotificationPayloadError.duplicate) { try gate.accept(fresh, payloadByteCount: 100, now: 102) }
    }

    @Test func strictSchemaRejectsUnknownCaseVariantAliasAndNestedForbiddenFields() throws {
        var gate = NotificationReplayExpiryGate(maxPayloadBytes: 4096)
        let valid = validJSON(id: "strict")
        _ = try NotificationPayloadValidator.decode(Data(valid.utf8), now: 100, gate: &gate)

        let probes = [
            jsonWithTopLevel("extra", value: "1"),
            jsonWithTopLevel("Action_Token", value: "\"x\""),
            jsonWithTopLevel("actionToken", value: "\"x\""),
            jsonWithTopLevel("auth", value: "\"x\""),
            jsonWithActionExtra("extra", value: "1"),
            jsonWithActionExtra("command", value: "\"rm\""),
            jsonWithActionExtra("actionToken", value: "\"x\""),
            jsonWithTitleObject("secret", value: "\"x\"")
        ]
        for probe in probes {
            var gate = NotificationReplayExpiryGate(maxPayloadBytes: 4096)
            #expect(throws: (any Error).self) { try NotificationPayloadValidator.decode(Data(probe.utf8), now: 100, gate: &gate) }
        }
    }

    @Test func publicValidatedDecodeRejectsOversizeBeforeParsingAndReplayGateChecks() throws {
        var gate = NotificationReplayExpiryGate(maxPayloadBytes: 1)
        let nonJSONOversized = Data(repeating: UInt8(ascii: "{"), count: 2)
        #expect(throws: NotificationPayloadError.oversized) { try NotificationPayloadValidator.decode(nonJSONOversized, now: 100, gate: &gate) }

        var gate2 = NotificationReplayExpiryGate(maxPayloadBytes: 4096)
        _ = try NotificationPayloadValidator.decode(Data(validJSON(id: "dup").utf8), now: 100, gate: &gate2)
        #expect(throws: NotificationPayloadError.duplicate) { try NotificationPayloadValidator.decode(Data(validJSON(id: "dup").utf8), now: 101, gate: &gate2) }
    }

    @Test func validatesIdentifierCharsetLengthsAndActionInboxConsistency() throws {
        let invalids = [
            validJSON(id: "bad space"),
            validJSON(id: String(repeating: "a", count: 129)),
            validJSON(id: "ok", nonce: "../../secret"),
            validJSON(id: "ok", inbox: "outer", action: "{\"inbox_id\":\"other\",\"type\":\"open_detail\"}"),
            validJSON(id: "ok", inbox: "outer", action: "{\"decision_id\":\"bad/id\",\"inbox_id\":\"outer\",\"type\":\"decision_review\"}")
        ]
        for json in invalids {
            var gate = NotificationReplayExpiryGate(maxPayloadBytes: 4096)
            #expect(throws: (any Error).self) { try NotificationPayloadValidator.decode(Data(json.utf8), now: 100, gate: &gate) }
        }
    }

    @Test func replayIdentityIsCollisionFreeAndExpiryBoundedByConfiguredMaxAge() throws {
        var gate = NotificationReplayExpiryGate(capacity: 4, maxPayloadBytes: 4096, maxClockSkewSeconds: 10, maxAgeSeconds: 50)
        try gate.accept(validPayload(id: "a|b", created: 100, expires: 120, nonce: "c"), payloadByteCount: 100, now: 100)
        try gate.accept(validPayload(id: "a", created: 100, expires: 120, nonce: "b|c"), payloadByteCount: 100, now: 100)

        var gate2 = NotificationReplayExpiryGate(maxPayloadBytes: 4096, maxAgeSeconds: 50)
        #expect(throws: NotificationPayloadError.invalidTimeRange) {
            try NotificationPayloadValidator.decode(Data(validJSON(id: "far", created: 100, expires: 10_000).utf8), now: 100, gate: &gate2)
        }
    }

    @Test func safeTitlesFailClosedForUnsafeStringsAndInvalidBounds() throws {
        #expect(throws: NotificationPayloadError.invalidTitleConfiguration) { try SafeNotificationTitle("hello", maxUTF8Bytes: 0, maxScalars: 10) }
        #expect(throws: NotificationPayloadError.invalidTitleConfiguration) { try SafeNotificationTitle("hello", maxUTF8Bytes: 10, maxScalars: -1) }
        #expect(try SafeNotificationTitle("deploy 🚀", maxUTF8Bytes: 9, maxScalars: 20).value == "deploy")
        let unsafe = ["/Users/alice/.ssh/id_rsa", "prod.example.com", "git@github.com:org/private.git", "password=hunter2", "token abc", "ssh://host/repo"]
        for raw in unsafe {
            #expect(try SafeNotificationTitle(raw).value == "OpenPaw notification")
        }
    }

    @Test func safeTitleDecodingSanitizesAndInvalidBoundsThrow() throws {
        let unsafe = try JSONDecoder().decode(SafeNotificationTitle.self, from: Data(#"{"value":"/Users/alice/.ssh/id_rsa"}"#.utf8))
        #expect(unsafe.value == "OpenPaw notification")
        #expect(throws: NotificationPayloadError.invalidTitleConfiguration) { try SafeNotificationTitle("hello", maxUTF8Bytes: 0, maxScalars: 10) }
        #expect(throws: NotificationPayloadError.invalidTitleConfiguration) { try SafeNotificationTitle("hello", maxUTF8Bytes: 10, maxScalars: -1) }
    }

    @Test func safeTitleFallbackNeverExceedsPositiveCallerBounds() throws {
        #expect(throws: NotificationPayloadError.invalidTitleConfiguration) { try SafeNotificationTitle("🚀", maxUTF8Bytes: 1, maxScalars: 64) }
        #expect(throws: NotificationPayloadError.invalidTitleConfiguration) { try SafeNotificationTitle("/Users/alice/.ssh/id_rsa", maxUTF8Bytes: 10, maxScalars: 64) }
        #expect(throws: NotificationPayloadError.invalidTitleConfiguration) { try SafeNotificationTitle("token abc", maxUTF8Bytes: 96, maxScalars: 1) }
        let title = try SafeNotificationTitle("👨‍👩‍👧‍👦 family", maxUTF8Bytes: 25, maxScalars: 10)
        #expect(title.value == "👨‍👩‍👧‍👦")
        #expect(title.value.utf8.count <= 25)
        #expect(title.value.unicodeScalars.count <= 10)
    }

    @Test func threadIdentifiersAreCollisionFreeForOpaqueIDsWithDelimiters() throws {
        let first = try NotificationHint(id: "first", hostID: "a|session:b", deviceID: "d", sessionID: "c", inboxID: "c", category: .message, risk: .low, createdAt: 10, expiresAt: 20, nonce: "n1", title: "Safe title", actionIntent: .openDetail(inboxID: "c"))
        let second = try NotificationHint(id: "second", hostID: "a", deviceID: "d", sessionID: "b|session:c", inboxID: "c", category: .message, risk: .low, createdAt: 10, expiresAt: 20, nonce: "n2", title: "Safe title", actionIntent: .openDetail(inboxID: "c"))
        let firstPresentation = LocalNotificationPresentationMapper.map(first)
        let secondPresentation = LocalNotificationPresentationMapper.map(second)
        #expect(first != second)
        #expect(firstPresentation.threadIdentifier != secondPresentation.threadIdentifier)
    }

    @Test func replayGateRejectsCapacityPressureInsteadOfEvictingUnexpiredIdentities() throws {
        var gate = NotificationReplayExpiryGate(capacity: 1, maxPayloadBytes: 4096, maxClockSkewSeconds: 10, maxAgeSeconds: 100)
        let first = validPayload(id: "first", created: 100, expires: 180, nonce: "n1")
        try gate.accept(first, payloadByteCount: 100, now: 100)
        #expect(throws: NotificationPayloadError.replayStorePressure) {
            try gate.accept(validPayload(id: "second", created: 101, expires: 181, nonce: "n2"), payloadByteCount: 100, now: 101)
        }
        #expect(throws: NotificationPayloadError.duplicate) {
            try gate.accept(first, payloadByteCount: 100, now: 102)
        }
    }

    @Test func invalidGateConfigurationFailsClosed() throws {
        var gate = NotificationReplayExpiryGate(capacity: 0, maxPayloadBytes: 4096)
        #expect(throws: NotificationPayloadError.invalidGateConfiguration) {
            try NotificationPayloadValidator.decode(Data(validJSON(id: "bad-gate").utf8), now: 100, gate: &gate)
        }
    }

    @Test func schemaRejectsForbiddenFieldsInsideNestedArraysBeforeCodable() throws {
        let nested = validJSON(id: "nested").replacingOccurrences(of: "\"title\":\"Safe title\"", with: "\"title\":[[{\"secret\":\"x\"}]]")
        var gate = NotificationReplayExpiryGate(maxPayloadBytes: 4096)
        #expect(throws: (any Error).self) {
            try NotificationPayloadValidator.decode(Data(nested.utf8), now: 100, gate: &gate)
        }
    }

    @Test func directConstructionAndDecodeValidateOpaqueIDsAndActionConsistency() throws {
        #expect(throws: NotificationPayloadError.invalidIdentifier) {
            try NotificationHint(id: "bad space", hostID: "h", deviceID: "d", sessionID: "s", inboxID: "inbox", category: .message, risk: .low, createdAt: 10, expiresAt: 20, nonce: "n", title: "Safe title", actionIntent: .openDetail(inboxID: "inbox"))
        }
        #expect(throws: NotificationPayloadError.invalidIdentifier) {
            try NotificationHint(id: "ok", hostID: "h", deviceID: "d", sessionID: "s", inboxID: "outer", category: .message, risk: .low, createdAt: 10, expiresAt: 20, nonce: "n", title: "Safe title", actionIntent: .openDetail(inboxID: "other"))
        }
        let badIDJSON = validJSON(id: "bad space")
        #expect(throws: NotificationPayloadError.invalidIdentifier) { try JSONDecoder().decode(NotificationHint.self, from: Data(badIDJSON.utf8)) }
        let badActionJSON = validJSON(id: "ok", inbox: "outer", action: "{\"inbox_id\":\"other\",\"type\":\"open_detail\"}")
        #expect(throws: NotificationPayloadError.invalidIdentifier) { try JSONDecoder().decode(NotificationHint.self, from: Data(badActionJSON.utf8)) }
    }

    @Test func directDecodeRejectsTopLevelUnknownForbiddenAliasAndCaseVariantKeys() throws {
        let probes = [
            jsonWithTopLevel("extra", value: "1"),
            jsonWithTopLevel("command", value: "\"rm\""),
            jsonWithTopLevel("Action_Token", value: "\"x\""),
            jsonWithTopLevel("actionToken", value: "\"x\""),
            jsonWithTopLevel("auth", value: "\"x\"")
        ]
        for json in probes {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(NotificationHint.self, from: Data(json.utf8)) }
        }
    }

    @Test func directDecodeRejectsActionIntentUnknownForbiddenAndAliasKeysByKind() throws {
        let directDecodeProbes = [
            validJSON(id: "direct-extra", action: "{\"extra\":1,\"inbox_id\":\"inbox\",\"type\":\"open_detail\"}"),
            validJSON(id: "direct-command", action: "{\"command\":\"rm\",\"inbox_id\":\"inbox\",\"type\":\"open_detail\"}"),
            validJSON(id: "direct-case", action: "{\"Action_Token\":\"x\",\"inbox_id\":\"inbox\",\"type\":\"open_detail\"}"),
            validJSON(id: "direct-alias", action: "{\"actionToken\":\"x\",\"inbox_id\":\"inbox\",\"type\":\"open_detail\"}"),
            validJSON(id: "direct-open-inbox", action: "{\"inbox_id\":\"inbox\",\"type\":\"open_inbox\"}"),
            validJSON(id: "direct-decision", action: "{\"decision_id\":\"decision\",\"extra\":1,\"inbox_id\":\"inbox\",\"type\":\"decision_review\"}")
        ]
        for json in directDecodeProbes {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(NotificationHint.self, from: Data(json.utf8)) }
        }
    }

    @Test func actionRouterDoesNotRouteInvalidDirectlyConstructedIDs() throws {
        #expect(throws: NotificationPayloadError.invalidIdentifier) { try ActionRouter.route(.openDetail(inboxID: "../../secret")) }
        #expect(throws: NotificationPayloadError.invalidIdentifier) { try ActionRouter.route(.decisionReview(inboxID: "inbox", decisionID: "../../secret")) }
        #expect(throws: NotificationPayloadError.invalidIdentifier) { try ActionRouter.route(.decisionReview(inboxID: String(repeating: "a", count: 129), decisionID: "decision")) }
        #expect(try ActionRouter.route(.openDetail(inboxID: "safe-inbox")) == .openDetail(inboxID: "safe-inbox", requiresAuthenticatedRefresh: false))
        #expect(try ActionRouter.route(.decisionReview(inboxID: "safe-inbox", decisionID: "decision")) == .openDetail(inboxID: "safe-inbox", requiresAuthenticatedRefresh: true))
    }

    @Test func standaloneActionIntentDecodeRejectsExtrasAliasesCaseVariantsAndInvalidIDs() throws {
        let invalidJSON = [
            "{\"extra\":1,\"inbox_id\":\"inbox\",\"type\":\"open_detail\"}",
            "{\"command\":\"rm\",\"inbox_id\":\"inbox\",\"type\":\"open_detail\"}",
            "{\"Action_Token\":\"x\",\"inbox_id\":\"inbox\",\"type\":\"open_detail\"}",
            "{\"actionToken\":\"x\",\"inbox_id\":\"inbox\",\"type\":\"open_detail\"}",
            "{\"inbox_id\":\"../../secret\",\"type\":\"open_detail\"}",
            "{\"inbox_id\":\"\",\"type\":\"open_detail\"}",
            "{\"decision_id\":\"../../secret\",\"inbox_id\":\"inbox\",\"type\":\"decision_review\"}",
            "{\"decision_id\":\"decision\",\"inbox_id\":\"\",\"type\":\"decision_review\"}",
            "{\"inbox_id\":\"inbox\",\"type\":\"open_inbox\"}"
        ]
        for json in invalidJSON {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(NotificationActionIntent.self, from: Data(json.utf8)) }
        }

        #expect(try JSONDecoder().decode(NotificationActionIntent.self, from: Data("{\"type\":\"open_inbox\"}".utf8)) == .openInbox)
        #expect(try JSONDecoder().decode(NotificationActionIntent.self, from: Data("{\"inbox_id\":\"inbox\",\"type\":\"open_detail\"}".utf8)) == .openDetail(inboxID: "inbox"))
        #expect(try JSONDecoder().decode(NotificationActionIntent.self, from: Data("{\"decision_id\":\"decision\",\"inbox_id\":\"inbox\",\"type\":\"decision_review\"}".utf8)) == .decisionReview(inboxID: "inbox", decisionID: "decision"))
    }

    @Test func directUngatedDecodePathIsUnavailable() throws {
        let mirror = String(describing: NotificationPayloadValidator.self)
        #expect(!mirror.isEmpty)
    }

    @Test func presentationAndRoutingAreNavigationOnlyByDefault() throws {
        let hint = validPayload(id: "n", created: 10, expires: 20, nonce: "x", category: .decisionRequired, intent: .decisionReview(inboxID: "inbox", decisionID: "decision"))
        #expect(hint.actionIntent.requiresForegroundAuthenticatedRefresh)
        #expect(!hint.actionIntent.carriesAuthorizationMaterial)
        let presentation = LocalNotificationPresentationMapper.map(hint)
        #expect(presentation.title == hint.title.value)
        #expect(presentation.body == "Open OpenPaw to review")
        #expect(presentation.categoryIdentifier == "openpaw.decision_required")
        #expect(presentation.threadIdentifier == "1:h|1:s|5:inbox")
        #expect(try ActionRouter.route(hint.actionIntent) == .openDetail(inboxID: "inbox", requiresAuthenticatedRefresh: true))
        #expect(ActionRouter.directAuthorizationIntent(for: hint.actionIntent) == nil)
    }
}

private func validPayload(id: String, created: Int64, expires: Int64, nonce: String, category: NotificationCategory = .message, intent: NotificationActionIntent = .openInbox) -> NotificationHint {
    try! NotificationHint(id: id, hostID: "h", deviceID: "d", sessionID: "s", inboxID: "inbox", category: category, risk: .low, createdAt: created, expiresAt: expires, nonce: nonce, title: "Safe title", actionIntent: intent)
}

private func validJSON(id: String, created: Int64 = 100, expires: Int64 = 150, nonce: String = "nonce", inbox: String = "inbox", action: String = "{\"inbox_id\":\"inbox\",\"type\":\"open_detail\"}") -> String {
    "{\"action_intent\":\(action),\"category\":\"message\",\"created_at\":\(created),\"device_id\":\"device\",\"expires_at\":\(expires),\"host_id\":\"host\",\"id\":\"__ID__\",\"inbox_id\":\"__INBOX__\",\"nonce\":\"__NONCE__\",\"risk\":\"low\",\"schema_version\":1,\"session_id\":\"session\",\"title\":\"Safe title\"}"
        .replacingOccurrences(of: "__ID__", with: id)
        .replacingOccurrences(of: "__INBOX__", with: inbox)
        .replacingOccurrences(of: "__NONCE__", with: nonce)
}

private func jsonWithTopLevel(_ key: String, value: String) -> String {
    var json = validJSON(id: "probe")
    json.removeLast()
    return json + ",\"__ID__\":\(value)}".replacingOccurrences(of: "__ID__", with: key)
}

private func jsonWithActionExtra(_ key: String, value: String) -> String {
    validJSON(id: "probe", action: "{\"inbox_id\":\"inbox\",\"type\":\"open_detail\",\"__ID__\":\(value)}".replacingOccurrences(of: "__ID__", with: key))
}

private func jsonWithTitleObject(_ key: String, value: String) -> String {
    validJSON(id: "probe").replacingOccurrences(of: "\"title\":\"Safe title\"", with: "\"title\":{\"__ID__\":\(value)}".replacingOccurrences(of: "__ID__", with: key))
}
