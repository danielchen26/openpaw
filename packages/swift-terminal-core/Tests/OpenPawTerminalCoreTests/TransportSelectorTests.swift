import XCTest

@testable import OpenPawTerminalCore

final class TransportSelectorTests: XCTestCase {
    private let selector = TransportSelector()
    private let etEnabledSelector = TransportSelector(
        experimentalFeatures: ExperimentalTransportFeatures(eternalTerminalInterop: true))
    private let everything: Set<TransportKind> = [.ssh, .mosh, .eternalTerminal]

    func testExperimentalTransportFeaturesDefaultToDisabled() {
        XCTAssertEqual(ExperimentalTransportFeatures(), .disabled)
        XCTAssertFalse(ExperimentalTransportFeatures().eternalTerminalInterop)
    }

    func testDefaultOrderExcludesEternalTerminalWhenFeatureGateIsDisabled() {
        let plan = selector.plan(for: Fixtures.host(), available: everything)
        XCTAssertEqual(plan.map(\.kind), [.mosh, .ssh])
        XCTAssertEqual(plan.map(\.reason), [.latencyPreference, .fallback])
        XCTAssertEqual(plan.map(\.priority), [0, 1])
    }

    func testDefaultOrderIncludesEternalTerminalWhenFeatureGateIsExplicitlyEnabled() {
        let plan = etEnabledSelector.plan(for: Fixtures.host(), available: everything)
        XCTAssertEqual(plan.map(\.kind), [.mosh, .eternalTerminal, .ssh])
        XCTAssertEqual(plan.map(\.reason), [.latencyPreference, .fallback, .fallback])
        XCTAssertEqual(plan.map(\.priority), [0, 1, 2])
    }

    func testLastSuccessfulEternalTerminalIsExcludedWhenFeatureGateIsDisabled() {
        let host = Fixtures.host(lastSuccessful: .eternalTerminal)
        let plan = selector.plan(for: host, available: everything)
        XCTAssertEqual(plan.map(\.kind), [.mosh, .ssh])
        XCTAssertEqual(plan.map(\.reason), [.latencyPreference, .fallback])
    }

    func testLastSuccessfulEternalTerminalLeadsThePlanWhenFeatureGateIsEnabled() {
        let host = Fixtures.host(lastSuccessful: .eternalTerminal)
        let plan = etEnabledSelector.plan(for: host, available: everything)
        XCTAssertEqual(plan.map(\.kind), [.eternalTerminal, .mosh, .ssh])
        XCTAssertEqual(plan.map(\.reason), [.lastKnownGood, .latencyPreference, .fallback])
    }

    func testPinnedEternalTerminalIsExcludedWhenFeatureGateIsDisabled() {
        let host = Fixtures.host(preferred: .eternalTerminal, lastSuccessful: .ssh)
        let plan = selector.plan(for: host, available: everything)
        XCTAssertEqual(plan.map(\.kind), [.ssh, .mosh])
        XCTAssertEqual(plan.map(\.reason), [.lastKnownGood, .latencyPreference])
    }

    func testPreferredEternalTerminalIsExcludedWhenFeatureGateIsDisabled() {
        let host = Fixtures.host(preferred: .eternalTerminal)
        let plan = selector.plan(for: host, available: everything)
        XCTAssertEqual(plan.map(\.kind), [.mosh, .ssh])
        XCTAssertEqual(plan.map(\.reason), [.latencyPreference, .fallback])
    }

    func testPinnedTransportBeatsLastKnownGoodWhenFeatureGateAllowsIt() {
        let host = Fixtures.host(preferred: .ssh, lastSuccessful: .eternalTerminal)
        let plan = etEnabledSelector.plan(for: host, available: everything)
        XCTAssertEqual(plan.map(\.kind), [.ssh, .eternalTerminal, .mosh])
        XCTAssertEqual(plan.map(\.reason), [.pinned, .lastKnownGood, .latencyPreference])
    }

    func testUnavailableTransportsAreFilteredOut() {
        let host = Fixtures.host(preferred: .mosh, lastSuccessful: .mosh)
        let plan = etEnabledSelector.plan(for: host, available: [.ssh, .eternalTerminal])
        XCTAssertEqual(plan.map(\.kind), [.eternalTerminal, .ssh])
        XCTAssertEqual(plan.map(\.reason), [.fallback, .fallback])
    }

    func testExplainsFallbackForHostWhoseLastSuccessWasEternalTerminal() {
        let host = Fixtures.host(lastSuccessful: .eternalTerminal)
        let plan = etEnabledSelector.plan(for: host, available: everything)
        let outcome: [TransportAttempt: TransportError] = [
            plan[0]: .connectionRefused(host: "beta.local", port: 2022),
            plan[1]: .remoteBinaryMissing(.mosh, command: "mosh-server"),
        ]

        XCTAssertEqual(
            selector.explain(outcome, plan: plan),
            """
            Eternal Terminal (last known good for this host) failed: connection refused by \
            beta.local:2022. Mosh (preferred for latency) failed: Mosh is not installed on the \
            host (`mosh-server` not found). Continued with SSH.
            """)
    }

    func testExplainsSingleAttemptExhaustionWithoutClaimingSSH() {
        let plan = selector.plan(for: Fixtures.host(), available: [.mosh, .eternalTerminal])
        XCTAssertEqual(plan.map(\.kind), [.mosh])
        let outcome: [TransportAttempt: TransportError] = [
            plan[0]: .remoteBinaryMissing(.mosh, command: "mosh-server")
        ]

        XCTAssertEqual(
            selector.explain(outcome, plan: plan),
            "Mosh (preferred for latency) failed: Mosh is not installed on the host "
                + "(`mosh-server` not found). No transport was able to connect.")
    }

    func testExplainsMoshToSSHContinuationFromActualPlan() {
        let plan = selector.plan(for: Fixtures.host(), available: everything)
        let outcome: [TransportAttempt: TransportError] = [
            plan[0]: .remoteBinaryMissing(.mosh, command: "mosh-server")
        ]

        XCTAssertEqual(
            selector.explain(outcome, plan: plan),
            "Mosh (preferred for latency) failed: Mosh is not installed on the host "
                + "(`mosh-server` not found). Continued with SSH.")
    }

    func testExplainsPinnedContinuationFromActualPlan() {
        let host = Fixtures.host(preferred: .ssh, lastSuccessful: .eternalTerminal)
        let plan = etEnabledSelector.plan(for: host, available: everything)
        let outcome: [TransportAttempt: TransportError] = [
            plan[0]: .connectionRefused(host: "beta.local", port: 22)
        ]

        XCTAssertEqual(
            selector.explain(outcome, plan: plan),
            "SSH (pinned for this host) failed: connection refused by beta.local:22. "
                + "Continued with Eternal Terminal.")
    }

    func testExplainsNoAvailableTransportsAsExhaustion() {
        let plan = selector.plan(for: Fixtures.host(), available: [])
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(
            selector.explain([:], plan: plan),
            "No transport was available to connect.")
    }

    func testExplainsTotalFailureWhenSSHAlsoFailed() {
        let plan = selector.plan(for: Fixtures.host(), available: everything)
        let outcome: [TransportAttempt: TransportError] = [
            plan[1]: .authenticationFailed(reason: "no acceptable key")
        ]
        XCTAssertEqual(
            selector.explain(outcome, plan: plan),
            "SSH (fallback) failed: authentication failed (no acceptable key). "
                + "No transport was able to connect.")
    }

    func testExplainsCleanConnection() {
        XCTAssertEqual(
            selector.explain([:]),
            "The preferred transport connected; no fallback was needed.")
    }

    func testStoreRecordsLastSuccessfulTransportPerHost() throws {
        let alpha = Fixtures.host(nickname: "alpha", hostname: "alpha.local")
        var beta = Fixtures.host(nickname: "beta")
        beta.id = UUID()
        var store = HostStore(hosts: [alpha, beta])

        try store.recordSuccessfulTransport(.eternalTerminal, for: alpha.id)
        XCTAssertEqual(store[alpha.id]?.lastSuccessfulTransport, .eternalTerminal)
        XCTAssertNil(store[beta.id]?.lastSuccessfulTransport)

        // The disabled default plan excludes ET, while the explicitly enabled
        // plan preserves the previous last-success behavior.
        let disabledPlan = selector.plan(for: store[alpha.id]!, available: everything)
        XCTAssertEqual(disabledPlan.first?.kind, .mosh)
        XCTAssertEqual(disabledPlan.first?.reason, .latencyPreference)

        let enabledPlan = etEnabledSelector.plan(for: store[alpha.id]!, available: everything)
        XCTAssertEqual(enabledPlan.first?.kind, .eternalTerminal)
        XCTAssertEqual(enabledPlan.first?.reason, .lastKnownGood)

        XCTAssertThrowsError(try store.recordSuccessfulTransport(.mosh, for: UUID())) { error in
            guard case HostStoreError.unknownHost = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testTransportErrorFallbackClassification() {
        XCTAssertTrue(TransportError.remoteBinaryMissing(.mosh, command: "mosh-server").allowsTransportFallback)
        XCTAssertTrue(TransportError.timeout.allowsTransportFallback)
        // A rejected key or bad credential will fail identically on every
        // transport, so the selector must not burn attempts on it.
        XCTAssertFalse(TransportError.authenticationFailed(reason: "bad password").allowsTransportFallback)
        XCTAssertFalse(TransportError.hostKeyChanged(expected: "SHA256:a", actual: "SHA256:b").allowsTransportFallback)
    }
}
