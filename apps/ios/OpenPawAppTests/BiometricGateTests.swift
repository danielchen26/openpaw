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

    func testGraceBoundaryIsInclusiveAndRelocks() {
        let decision = BiometricGate.decide(
            policy: policy(grace: 120),
            lastUnlockedAt: epoch,
            leftForegroundAt: epoch.addingTimeInterval(10),
            now: epoch.addingTimeInterval(10 + 120)
        )
        XCTAssertEqual(decision, .authenticate)
    }

    func testZeroGraceRelocksOnEveryBackgroundTrip() {
        let decision = BiometricGate.decide(
            policy: policy(grace: 0),
            lastUnlockedAt: epoch,
            leftForegroundAt: epoch.addingTimeInterval(1),
            now: epoch.addingTimeInterval(1.001)
        )
        XCTAssertEqual(decision, .authenticate)
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

    /// A user who moves the clock backwards must not thereby extend the grace period indefinitely.
    func testBackwardsClockFailsClosed() {
        let decision = BiometricGate.decide(
            policy: policy(grace: 600),
            lastUnlockedAt: epoch,
            leftForegroundAt: epoch.addingTimeInterval(100),
            now: epoch.addingTimeInterval(50)
        )
        XCTAssertEqual(decision, .authenticate)
    }

    @MainActor
    func testInboxURLReevaluatesExpiredGraceBeforeOpeningTheRoute() {
        let gate = GateController(
            policy: policy(grace: 120),
            lastUnlockedAt: epoch,
            leftForegroundAt: epoch.addingTimeInterval(10),
            now: epoch.addingTimeInterval(10 + 119)
        )
        XCTAssertEqual(gate.decision, .unlocked)

        var cancellationCount = 0
        let mayOpen = InboxURLAccessGate.refreshAndAllow(
            gate,
            now: epoch.addingTimeInterval(10 + 120),
            onDenied: { cancellationCount += 1 }
        )

        XCTAssertFalse(mayOpen)
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertEqual(gate.decision, .authenticate)
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
        wiring.receiveInboxURL(deniedRoute.url)

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
        wiring.receiveInboxURL(route.url)

        XCTAssertNil(wiring.pendingInboxRoute)
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

        XCTAssertEqual(auth, .password(reference: try KeychainReference(identifier: "quick-connect/password/Studio-login")))
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
        XCTAssertEqual(recorder.deletes, [try KeychainReference(identifier: "quick-connect/private-key/Studio-key")])
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
