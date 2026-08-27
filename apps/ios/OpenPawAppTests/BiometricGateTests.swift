import XCTest
import OpenPawTerminalCore
@testable import OpenPawProtocol
@testable import OpenPawUI

@testable import OpenPawApp

/// The re-gate decision is the only thing standing between a borrowed phone and an approve button, so every branch
/// is pinned here rather than left to a lifecycle callback nobody reads.
final class BiometricGateTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func policy(
        enabled: Bool = true,
        grace: TimeInterval = 120,
        unavailable: String? = nil
    ) -> GatePolicy {
        GatePolicy(requiresBiometrics: enabled, graceInterval: grace, unavailableReason: unavailable)
    }

    private func pairingURL(
        nickname: String,
        issuedAt: Date = Date(),
        expiresAfter: TimeInterval = 240
    ) -> URL {
        let envelope = QuickConnectEnvelopeV1(
            issuedAt: issuedAt,
            expiresAt: issuedAt.addingTimeInterval(expiresAfter),
            sessionID: "ses_0123456789abcdef01234567",
            hostAPIPort: 8765,
            profile: .operator,
            pairingCode: "ABCD-EFGH-IJKL-MNOP-QRST-UVWX",
            nickname: nickname,
            username: "operator",
            targets: [.init(hostname: "macbook.tailnet.example", source: .magicDNS)]
        )
        return try! QuickConnectLinkCodec(now: { issuedAt }).encode(envelope)
    }

    func testDisabledPolicyNeverGates() {
        let decision = BiometricGate.decide(
            policy: policy(enabled: false),
            lastUnlockedAt: nil,
            leftForegroundAt: epoch,
            now: epoch.addingTimeInterval(10_000)
        )
        XCTAssertEqual(decision, .unlocked)
    }

    func testDisabledPolicyWinsOverUnavailableBiometry() {
        let decision = BiometricGate.decide(
            policy: policy(enabled: false, unavailable: "No passcode is set."),
            lastUnlockedAt: nil,
            leftForegroundAt: nil,
            now: epoch
        )
        XCTAssertEqual(decision, .unlocked)
    }

    func testColdLaunchRequiresAuthentication() {
        let decision = BiometricGate.decide(
            policy: policy(),
            lastUnlockedAt: nil,
            leftForegroundAt: nil,
            now: epoch
        )
        XCTAssertEqual(decision, .authenticate)
    }

    func testUnavailableBiometryIsReportedRatherThanSilentlyUnlocking() {
        let decision = BiometricGate.decide(
            policy: policy(unavailable: "No passcode is set on this device."),
            lastUnlockedAt: epoch,
            leftForegroundAt: nil,
            now: epoch
        )
        XCTAssertEqual(decision, .unavailable(reason: "No passcode is set on this device."))
    }

    func testUnlockedAndNeverBackgroundedStaysUnlocked() {
        let decision = BiometricGate.decide(
            policy: policy(),
            lastUnlockedAt: epoch,
            leftForegroundAt: nil,
            now: epoch.addingTimeInterval(86_400)
        )
        XCTAssertEqual(decision, .unlocked)
    }

    func testInsideGraceIntervalStaysUnlocked() {
        let decision = BiometricGate.decide(
            policy: policy(grace: 120),
            lastUnlockedAt: epoch,
            leftForegroundAt: epoch.addingTimeInterval(10),
            now: epoch.addingTimeInterval(10 + 119)
        )
        XCTAssertEqual(decision, .unlocked)
    }

    /// One successful unlock covers the whole launch: neither the grace boundary nor any amount of time away
    /// re-prompts. The device's own lock screen guards the phone; re-prompting inside the app made it unusable.
    func testUnlockedOnceNeverRePromptsThisLaunchEvenPastGrace() {
        let decision = BiometricGate.decide(
            policy: policy(grace: 120),
            lastUnlockedAt: epoch,
            leftForegroundAt: epoch.addingTimeInterval(10),
            now: epoch.addingTimeInterval(10 + 86_400)
        )
        XCTAssertEqual(decision, .unlocked)
    }

    func testZeroGraceStillDoesNotRePromptAfterFirstUnlock() {
        let decision = BiometricGate.decide(
            policy: policy(grace: 0),
            lastUnlockedAt: epoch,
            leftForegroundAt: epoch.addingTimeInterval(1),
            now: epoch.addingTimeInterval(1.001)
        )
        XCTAssertEqual(decision, .unlocked)
    }

    /// A background episode that predates the unlock was already paid for by that unlock. Without this the app
    /// re-prompts immediately after every successful authentication, because the stale marker never clears.
    func testBackgroundEpisodeBeforeLastUnlockIsAlreadyAccountedFor() {
        let decision = BiometricGate.decide(
            policy: policy(grace: 0),
            lastUnlockedAt: epoch.addingTimeInterval(500),
            leftForegroundAt: epoch.addingTimeInterval(100),
            now: epoch.addingTimeInterval(501)
        )
        XCTAssertEqual(decision, .unlocked)
    }

    /// Equal timestamps mean the unlock happened at or after the backgrounding was recorded, which is the
    /// resume-then-authenticate ordering. It must not re-prompt.
    func testUnlockAtSameInstantAsBackgroundingDoesNotRePrompt() {
        let decision = BiometricGate.decide(
            policy: policy(grace: 0),
            lastUnlockedAt: epoch,
            leftForegroundAt: epoch,
            now: epoch.addingTimeInterval(9_999)
        )
        XCTAssertEqual(decision, .unlocked)
    }

    /// A backwards clock cannot matter when time no longer participates: an unlocked launch stays unlocked.
    func testBackwardsClockCannotRePromptAnUnlockedLaunch() {
        let decision = BiometricGate.decide(
            policy: policy(grace: 600),
            lastUnlockedAt: epoch,
            leftForegroundAt: epoch.addingTimeInterval(100),
            now: epoch.addingTimeInterval(50)
        )
        XCTAssertEqual(decision, .unlocked)
    }

    @MainActor
    func testInboxURLStaysOpenableOnceUnlockedAndBlockedBeforeFirstUnlock() {
        let unlocked = GateController(
            policy: policy(grace: 120),
            lastUnlockedAt: epoch,
            leftForegroundAt: epoch.addingTimeInterval(10),
            now: epoch.addingTimeInterval(10 + 119)
        )
        XCTAssertEqual(unlocked.decision, .unlocked)
        XCTAssertTrue(InboxURLAccessGate.refreshAndAllow(unlocked, now: epoch.addingTimeInterval(10 + 9_999)))
        XCTAssertEqual(unlocked.decision, .unlocked)

        let neverUnlocked = GateController(
            policy: policy(grace: 120),
            lastUnlockedAt: nil,
            leftForegroundAt: nil,
            now: epoch
        )
        XCTAssertEqual(neverUnlocked.decision, .authenticate)
        var cancellationCount = 0
        let mayOpen = InboxURLAccessGate.refreshAndAllow(
            neverUnlocked,
            now: epoch.addingTimeInterval(1),
            onDenied: { cancellationCount += 1 }
        )
        XCTAssertFalse(mayOpen)
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertEqual(neverUnlocked.decision, .authenticate)
    }

    @MainActor
    func testSharedSettingsChangesImmediatelyDrivePolicyAndDecision() {
        let suite = "openpaw.gate.shared.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = OpenPawSettings(defaults: defaults)
        settings.requiresBiometricGate = true
        settings.biometricGraceInterval = 120
        let gate = GateController(settings: settings)
        XCTAssertTrue(gate.policy.requiresBiometrics)
        XCTAssertEqual(gate.decision, .authenticate)

        settings.requiresBiometricGate = false
        settings.biometricGraceInterval = 0

        XCTAssertFalse(gate.policy.requiresBiometrics)
        XCTAssertEqual(gate.policy.graceInterval, 0)
        XCTAssertEqual(gate.decision, .unlocked)
        XCTAssertEqual(defaults.object(forKey: GateController.enabledKey) as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "lock.graceInterval") as? Double, 0)
    }

    @MainActor
    func testDeniedLockedInboxURLCannotOpenAfterLaterUnlock() {
        let wiring = AppWiring()
        wiring.gate.policy = policy()
        XCTAssertEqual(wiring.gate.decision, .authenticate)

        let deniedRoute = InboxRoute(
            hostID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            itemID: InboxID(rawValue: "inb_0123456789abcdef01234567")
        )
        wiring.receiveOpenPawURL(deniedRoute.url)

        XCTAssertNil(wiring.pendingInboxRoute)

        wiring.gate.policy = policy(enabled: false)
        wiring.openPendingInboxRouteIfUnlocked()

        XCTAssertNil(wiring.pendingInboxRoute)
    }

    @MainActor
    func testUnlockedInboxURLStillQueuesForDelivery() {
        let wiring = AppWiring()
        wiring.gate.policy = policy(enabled: false)
        XCTAssertEqual(wiring.gate.decision, .unlocked)

        let route = InboxRoute(
            hostID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            itemID: InboxID(rawValue: "inb_abcdefabcdefabcdefabcdef")
        )
        wiring.receiveOpenPawURL(route.url)

        XCTAssertNil(wiring.pendingInboxRoute)
    }

    @MainActor
    func testUnlockedPairingURLDecodesAndOpensOneQuickConnectProposal() {
        let wiring = AppWiring()
        wiring.gate.policy = policy(enabled: false)

        wiring.receiveOpenPawURL(pairingURL(nickname: "MacBook Pro"))

        XCTAssertEqual(wiring.quickConnectCoordinator.proposal?.nickname, "MacBook Pro")
        XCTAssertEqual(wiring.quickConnectCoordinator.stage, .reviewing)
        XCTAssertNil(wiring.pendingQuickConnectProposal)
    }

    @MainActor
    func testLockedPairingReceiptDoesNotBypassGateWhilePending() {
        let wiring = AppWiring()
        wiring.gate.policy = policy()
        XCTAssertEqual(wiring.gate.decision, .authenticate)

        wiring.receiveOpenPawURL(pairingURL(nickname: "Locked Mac"))

        XCTAssertEqual(wiring.pendingQuickConnectProposal?.nickname, "Locked Mac")
        XCTAssertNil(wiring.quickConnectCoordinator.proposal)
    }

    @MainActor
    func testInvalidPairingURLClearsOnlyPendingQuickConnectAndNeverReplays() {
        let wiring = AppWiring()
        wiring.gate.policy = policy()
        let inbox = InboxRoute(
            hostID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            itemID: InboxID(rawValue: "inb_111111111111111111111111")
        )
        wiring.pendingInboxRoute = inbox
        wiring.pendingQuickConnectProposal = try! QuickConnectLinkCodec().decode(pairingURL(nickname: "Stale Mac"))

        wiring.receiveOpenPawURL(URL(string: "openpaw://pair#v1.invalid")!)

        XCTAssertNil(wiring.pendingQuickConnectProposal)
        XCTAssertEqual(wiring.pendingInboxRoute, inbox)

        wiring.gate.policy = policy(enabled: false)
        wiring.openPendingQuickConnectIfUnlocked()
        XCTAssertNil(wiring.quickConnectCoordinator.proposal)
    }

    @MainActor
    func testNewestValidPendingPairingLinkSupersedesOlderWhileGateRemainsLocked() {
        let wiring = AppWiring()
        wiring.gate.policy = policy()
        XCTAssertEqual(wiring.gate.decision, .authenticate)
        let inbox = InboxRoute(
            hostID: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            itemID: InboxID(rawValue: "inb_222222222222222222222222")
        )
        wiring.pendingInboxRoute = inbox

        wiring.receiveOpenPawURL(pairingURL(nickname: "Older Mac"))
        wiring.receiveOpenPawURL(pairingURL(nickname: "Newest Mac"))

        XCTAssertNil(wiring.quickConnectCoordinator.proposal)
        XCTAssertEqual(wiring.pendingQuickConnectProposal?.nickname, "Newest Mac")
        XCTAssertEqual(wiring.pendingInboxRoute, inbox)

        wiring.gate.policy = policy(enabled: false)
        wiring.openPendingQuickConnectIfUnlocked()

        XCTAssertEqual(wiring.quickConnectCoordinator.proposal?.nickname, "Newest Mac")
        XCTAssertNil(wiring.pendingQuickConnectProposal)
    }

    @MainActor
    func testPendingPairingLinkThatExpiresBeforeUnlockIsDiscardedAndCannotReplay() {
        let wiring = AppWiring()
        wiring.gate.policy = policy()
        let receivedAt = Date()
        let inbox = InboxRoute(
            hostID: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
            itemID: InboxID(rawValue: "inb_333333333333333333333333")
        )
        wiring.pendingInboxRoute = inbox

        wiring.receiveOpenPawURL(
            pairingURL(nickname: "Expired While Locked", issuedAt: receivedAt, expiresAfter: 1)
        )

        XCTAssertEqual(wiring.pendingQuickConnectProposal?.nickname, "Expired While Locked")
        XCTAssertNil(wiring.quickConnectCoordinator.proposal)

        wiring.gate.policy = policy(enabled: false)
        wiring.openPendingQuickConnectIfUnlocked(now: receivedAt.addingTimeInterval(2))

        XCTAssertNil(wiring.pendingQuickConnectProposal)
        XCTAssertNil(wiring.quickConnectCoordinator.proposal)
        XCTAssertEqual(wiring.pendingInboxRoute, inbox)

        wiring.openPendingQuickConnectIfUnlocked(now: receivedAt.addingTimeInterval(3))
        XCTAssertNil(wiring.quickConnectCoordinator.proposal)
    }

    func testScannerRejectsNonOpenPawTextAndOrdinaryWebLinksInPlace() {
        let now = Date()
        var scanner = OpenPawScannerPolicy(now: { now })

        XCTAssertEqual(scanner.receive("not a URL"), .rejected)
        XCTAssertEqual(scanner.receive("https://example.com/pair"), .rejected)
        XCTAssertFalse(scanner.isPaused)
    }

    func testScannerAcceptsOnlyOneOpenPawPayloadAndPauses() {
        let now = Date()
        var scanner = OpenPawScannerPolicy(now: { now })
        let first = pairingURL(nickname: "First Mac", issuedAt: now)
        let second = pairingURL(nickname: "Second Mac", issuedAt: now)

        guard case .accepted = scanner.receive(first.absoluteString) else {
            return XCTFail("Expected the first valid OpenPaw payload to be accepted")
        }
        XCTAssertTrue(scanner.isPaused)
        XCTAssertEqual(scanner.receive(second.absoluteString), .ignored)
    }

    @MainActor
    func testScannerAcceptedURLFeedsTheSameOpenPawBoundaryAsExternalLinks() {
        let now = Date()
        let url = pairingURL(nickname: "Scanned Mac", issuedAt: now)
        var scanner = OpenPawScannerPolicy(now: { now })
        let wiring = AppWiring()
        wiring.gate.policy = policy(enabled: false)

        if case .accepted(let receivedURL) = scanner.receive(url.absoluteString) {
            wiring.receiveOpenPawURL(receivedURL)
        } else {
            XCTFail("Expected an accepted OpenPaw scanner payload")
        }

        XCTAssertEqual(wiring.quickConnectCoordinator.proposal?.nickname, "Scanned Mac")
    }

    func testScannerCancellationProducesNoURLAndLeavesNavigationUntouched() {
        var scanner = OpenPawScannerPolicy()
        var navigation = "add-device"

        let outcome = scanner.cancel()
        if case .accepted = outcome { navigation = "quick-connect" }

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(navigation, "add-device")
    }

    func testPromptCopyNamesTheProtectedThing() {
        XCTAssertEqual(
            BiometricGate.prompt(for: .launch),
            "Unlock OpenPaw to see your agent sessions and approve requests."
        )
        XCTAssertEqual(
            BiometricGate.prompt(for: .returnedFromBackground(awayFor: 125)),
            "OpenPaw locked after 2 minutes away. Unlock to approve requests again."
        )
        XCTAssertEqual(BiometricGate.formattedAway(1), "1 seconds")
        XCTAssertEqual(BiometricGate.formattedAway(60), "a minute")
        XCTAssertEqual(BiometricGate.formattedAway(3_600), "an hour")
    }

    func testOfferedGraceLabels() {
        XCTAssertEqual(GatePolicy.graceLabel(0), "Every time")
        XCTAssertEqual(GatePolicy.graceLabel(30), "After 30 seconds")
        XCTAssertEqual(GatePolicy.graceLabel(60), "After 1 minute")
        XCTAssertEqual(GatePolicy.graceLabel(600), "After 10 minutes")
    }
}

final class QuickConnectKeychainCredentialInstallerTests: XCTestCase {
    func testPasswordStorageIsDeviceLocalWithoutUserPresence() async throws {
        let recorder = CredentialStoreRecorder()
        let installer = QuickConnectKeychainCredentialInstaller(storeSecret: recorder.store, deleteSecret: recorder.delete)

        let auth = try await installer.install(.password(label: "Studio login", secret: "pw"))

        guard case .password(let reference) = auth else { return XCTFail("Expected password reference") }
        XCTAssertTrue(reference.identifier.hasPrefix("quick-connect/password/"))
        XCTAssertTrue(reference.identifier.hasSuffix("/Studio-login"))
        XCTAssertEqual(recorder.writes.map(\.requiresUserPresence), [false])
        XCTAssertEqual(String(data: recorder.writes[0].data, encoding: .utf8), "pw")
    }

    func testPrivateKeyRequiresUserPresenceAndCleansUpPartialWrites() async throws {
        let recorder = CredentialStoreRecorder(failOnWrite: 2)
        let installer = QuickConnectKeychainCredentialInstaller(storeSecret: recorder.store, deleteSecret: recorder.delete)

        do {
            _ = try await installer.install(.privateKey(label: "Studio key", key: Data("key".utf8), passphraseLabel: "Studio passphrase", passphrase: "pass"))
            XCTFail("Expected storage failure")
        } catch QuickConnectCredentialInstallError.storageFailed {}

        XCTAssertEqual(recorder.writes.map(\.requiresUserPresence), [true, false])
        XCTAssertEqual(recorder.deletes, [recorder.writes[0].reference])
        XCTAssertTrue(recorder.writes[0].reference.identifier.hasPrefix("quick-connect/private-key/"))
        XCTAssertTrue(recorder.writes[0].reference.identifier.hasSuffix("/Studio-key"))
    }

    func testRepeatedPasswordInstallsUseUniqueReferences() async throws {
        let recorder = CredentialStoreRecorder()
        let installer = QuickConnectKeychainCredentialInstaller(storeSecret: recorder.store, deleteSecret: recorder.delete)

        let first = try await installer.install(.password(label: "Studio login", secret: "pw"))
        let second = try await installer.install(.password(label: "Studio login", secret: "pw"))

        guard case .password(let firstRef) = first, case .password(let secondRef) = second else { return XCTFail("Expected password references") }
        XCTAssertNotEqual(firstRef, secondRef)
        XCTAssertEqual(recorder.writes.map(\.reference), [firstRef, secondRef])
    }
}

private final class CredentialStoreRecorder: @unchecked Sendable {
    struct Write { var data: Data; var reference: KeychainReference; var requiresUserPresence: Bool }
    private(set) var writes: [Write] = []
    private(set) var deletes: [KeychainReference] = []
    let failOnWrite: Int?

    init(failOnWrite: Int? = nil) { self.failOnWrite = failOnWrite }

    func store(_ data: Data, _ reference: KeychainReference, _ requiresUserPresence: Bool) throws {
        writes.append(Write(data: data, reference: reference, requiresUserPresence: requiresUserPresence))
        if writes.count == failOnWrite { throw QuickConnectCredentialInstallError.storageFailed }
    }

    func delete(_ reference: KeychainReference) throws { deletes.append(reference) }
}
