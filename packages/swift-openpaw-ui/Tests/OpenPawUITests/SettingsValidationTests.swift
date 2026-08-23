import Foundation
import SwiftUI
import XCTest

@testable import OpenPawUI

@MainActor
final class SettingsValidationTests: XCTestCase {
    private func defaults(_ name: String = UUID().uuidString) -> UserDefaults {
        let suite = "openpaw.settings.validation.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testFutureSnapshotVersionRejectsWithoutMutatingSettings() throws {
        let settings = OpenPawSettings(defaults: defaults())
        let before = settings.snapshot()
        let data = Data(#"{"schema_version":999,"requires_biometric_gate":false}"#.utf8)

        XCTAssertThrowsError(try SettingsImportProposal.parse(data, current: settings))
        XCTAssertEqual(settings.snapshot(), before)
    }

    func testInvalidBudgetsAndPortsRejectWithoutMutating() throws {
        let settings = OpenPawSettings(defaults: defaults())
        for json in [
            #"{"schema_version":2,"event_budget_per_session":0}"#,
            #"{"schema_version":2,"event_budget_per_session":-1}"#,
            #"{"schema_version":2,"preview_port":0}"#,
            #"{"schema_version":2,"preview_port":65536}"#,
        ] {
            XCTAssertThrowsError(try SettingsImportProposal.parse(Data(json.utf8), current: settings))
        }
    }

    func testBiometricDisableRequiresExplicitSecurityReductionConfirmation() throws {
        let settings = OpenPawSettings(defaults: defaults())
        settings.requiresBiometricGate = true
        let snapshot = settings.snapshot()
        var reduced = snapshot
        reduced.requiresBiometricGate = false
        let data = try JSONEncoder.openPawSettings.encode(reduced)

        let proposal = try SettingsImportProposal.parse(data, current: settings)
        XCTAssertEqual(proposal.securityReductions, [.biometricProtectionDisabled])
        XCTAssertThrowsError(try settings.apply(proposal, confirmSecurityReductions: false))
        try settings.apply(proposal, confirmSecurityReductions: true)
        XCTAssertFalse(settings.requiresBiometricGate)
    }

    func testEventBudgetShortcutPreviewAndGraceSurviveReload() throws {
        let suite = "openpaw.settings.validation.reload.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = OpenPawSettings(defaults: defaults)
        settings.eventBudgetPerSession = 5_000
        settings.isShortcutBarVisible = false
        settings.previewPort = 8080
        settings.biometricGraceInterval = 42

        let reloaded = OpenPawSettings(defaults: defaults)
        XCTAssertEqual(reloaded.eventBudgetPerSession, 5_000)
        XCTAssertFalse(reloaded.isShortcutBarVisible)
        XCTAssertEqual(reloaded.previewPort, 8080)
        XCTAssertEqual(reloaded.biometricGraceInterval, 42)
    }

    func testCategoryResetProposalIsScopedAndStable() throws {
        let settings = OpenPawSettings(defaults: defaults())
        settings.terminalFontSize = 20
        settings.previewPort = 8080

        let proposal = SettingsImportProposal.reset(SettingsResetCategory.appearanceAndTerminal, current: settings)
        XCTAssertTrue(proposal.changes.contains { $0.controlID == "terminal-font-size" })
        XCTAssertFalse(proposal.changes.contains { $0.controlID == "preview-port" })
        XCTAssertEqual(proposal.changes.map(\.controlID), proposal.changes.map(\.controlID).sorted())
    }

    func testRootViewUsesInjectedSettingsInstance() throws {
        let settings = OpenPawSettings(defaults: defaults())
        settings.scrollbackLines = 1_000
        let view = RootView(model: OpenPawModel(settings: settings), terminalSurface: { AnyView(EmptyView()) }, settings: settings)
        let reflected = Mirror(reflecting: view).children.first { $0.label == "settings" }?.value as? OpenPawSettings
        XCTAssertTrue(reflected === settings)
    }
}
