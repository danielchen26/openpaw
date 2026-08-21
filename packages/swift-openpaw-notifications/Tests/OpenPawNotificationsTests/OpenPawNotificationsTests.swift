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
            #expect(throws: NotificationPayloadError.forbiddenField(key)) { try NotificationPayloadValidator.decode(Data(json.utf8), now: 10) }
        }
        #expect(throws: NotificationPayloadError.malformed) { try NotificationPayloadValidator.decode(Data("[]".utf8), now: 10) }
    }

    @Test func redactsAndTruncatesSafeTitles() throws {
        let title = try SafeNotificationTitle("tok_secret=abc 🚀🚀🚀🚀🚀🚀🚀🚀", maxUTF8Bytes: 24, maxScalars: 8)
        #expect(!title.value.localizedCaseInsensitiveContains("secret"))
        #expect(title.value.utf8.count <= 24)
        #expect(title.value.unicodeScalars.count <= 8)
    }

    @Test func gateRejectsExpiredFutureSkewStaleOversizedDuplicateAndEvicts() throws {
        var gate = NotificationReplayExpiryGate(capacity: 2, maxPayloadBytes: 512, maxClockSkewSeconds: 30, maxAgeSeconds: 120)
        let fresh = validPayload(id: "a", created: 100, expires: 150, nonce: "na")
        try gate.accept(fresh, payloadByteCount: 100, now: 100)
        #expect(throws: NotificationPayloadError.duplicate) { try gate.accept(fresh, payloadByteCount: 100, now: 101) }
        #expect(throws: NotificationPayloadError.expired) { try gate.accept(validPayload(id: "b", created: 100, expires: 150, nonce: "nb"), payloadByteCount: 100, now: 151) }
        #expect(throws: NotificationPayloadError.futureSkew) { try gate.accept(validPayload(id: "c", created: 200, expires: 250, nonce: "nc"), payloadByteCount: 100, now: 100) }
        #expect(throws: NotificationPayloadError.stale) { try gate.accept(validPayload(id: "d", created: 1, expires: 200, nonce: "nd"), payloadByteCount: 100, now: 150) }
        #expect(throws: NotificationPayloadError.oversized) { try gate.accept(validPayload(id: "e", created: 100, expires: 150, nonce: "ne"), payloadByteCount: 513, now: 100) }
        try gate.accept(validPayload(id: "b", created: 100, expires: 150, nonce: "nb"), payloadByteCount: 100, now: 100)
        try gate.accept(validPayload(id: "c", created: 100, expires: 150, nonce: "nc"), payloadByteCount: 100, now: 100)
        try gate.accept(fresh, payloadByteCount: 100, now: 102)
    }

    @Test func presentationAndRoutingAreNavigationOnlyByDefault() throws {
        let hint = validPayload(id: "n", created: 10, expires: 20, nonce: "x", category: .decisionRequired, intent: .decisionReview(inboxID: "inbox", decisionID: "decision"))
        #expect(hint.actionIntent.requiresForegroundAuthenticatedRefresh)
        #expect(!hint.actionIntent.carriesAuthorizationMaterial)
        let presentation = LocalNotificationPresentationMapper.map(hint)
        #expect(presentation.title == hint.title.value)
        #expect(presentation.body == "Open OpenPaw to review")
        #expect(presentation.categoryIdentifier == "openpaw.decision_required")
        #expect(presentation.threadIdentifier == "host:h/session:s/inbox:inbox")
        #expect(ActionRouter.route(hint.actionIntent) == .openDetail(inboxID: "inbox", requiresAuthenticatedRefresh: true))
        #expect(ActionRouter.directAuthorizationIntent(for: hint.actionIntent) == nil)
    }
}

private func validPayload(id: String, created: Int64, expires: Int64, nonce: String, category: NotificationCategory = .message, intent: NotificationActionIntent = .openInbox) -> NotificationHint {
    try! NotificationHint(id: id, hostID: "h", deviceID: "d", sessionID: "s", inboxID: "inbox", category: category, risk: .low, createdAt: created, expiresAt: expires, nonce: nonce, title: "Safe title", actionIntent: intent)
}
