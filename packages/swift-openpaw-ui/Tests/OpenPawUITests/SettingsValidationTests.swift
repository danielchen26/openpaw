import Foundation
import SwiftUI
import OpenPawProtocol
import OpenPawTerminalCore
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

        let proposal = try SettingsImportProposal.reset(SettingsResetCategory.appearanceAndTerminal, current: settings)
        XCTAssertTrue(proposal.changes.contains { $0.controlID == "terminal-font-size" })
        XCTAssertFalse(proposal.changes.contains { $0.controlID == "preview-port" })
        XCTAssertEqual(proposal.changes.map(\.controlID), proposal.changes.map(\.controlID).sorted())
    }

    func testSnapshotDoesNotMutateEventBudget() throws {
        let settings = OpenPawSettings(defaults: defaults())
        settings.eventBudgetPerSession = 500
        let snapshot = settings.snapshot()
        XCTAssertEqual(snapshot.eventBudgetPerSession, 500)
        XCTAssertEqual(settings.eventBudgetPerSession, 500)
    }

    func testImportRejectsMalformedHostIDsAndUnsafeShortcutIDs() throws {
        let settings = OpenPawSettings(defaults: defaults())
        var snapshot = settings.snapshot()
        snapshot.sessionProfiles = ["not-a-uuid": SessionProfile()]
        XCTAssertThrowsError(try SettingsImportProposal.parse(try JSONEncoder.openPawSettings.encode(snapshot), current: settings))

        let unsafeIDs = [".", "..", "../x", "x%2Fy", "bad/id", "", String(repeating: "a", count: 65)]
        for id in unsafeIDs {
            var candidate = settings.snapshot()
            candidate.shortcuts = ShortcutSet(shortcuts: [Shortcut(id: id, label: "secret label", payload: .literal("SECRET_PAYLOAD"), order: 1)])
            XCTAssertThrowsError(try SettingsImportProposal.parse(try JSONEncoder.openPawSettings.encode(candidate), current: settings), id)
        }
    }

    func testImportDiffIncludesRedactedShortcutAndSessionProfileChanges() throws {
        let settings = OpenPawSettings(defaults: defaults())
        let host = UUID().uuidString
        var snapshot = settings.snapshot()
        snapshot.shortcuts = ShortcutSet(shortcuts: [Shortcut(id: "safe_id-1", label: "deploy", payload: .literal("SECRET_TOKEN=abc"), order: 10)])
        snapshot.sessionProfiles = [host: SessionProfile(lastConnectedAt: Date(timeIntervalSince1970: 10))]
        let proposal = try SettingsImportProposal.parse(try JSONEncoder.openPawSettings.encode(snapshot), current: settings)
        let ids = proposal.changes.map(\.controlID)
        XCTAssertTrue(ids.contains("shortcut.safe_id-1"))
        XCTAssertTrue(ids.contains("session-profile.\(host)"))
        XCTAssertFalse(proposal.changes.contains { $0.oldDisplayValue.contains("SECRET") || $0.newDisplayValue.contains("SECRET") })
        XCTAssertEqual(proposal.changes.map { [$0.category.rawValue, $0.controlID] }, proposal.changes.map { [$0.category.rawValue, $0.controlID] }.sorted { $0.lexicographicallyPrecedes($1) })
    }

    func testImportDiffDetectsRedactedPayloadAndProfileContentChanges() throws {
        let settings = OpenPawSettings(defaults: defaults())
        let host = UUID().uuidString
        var baseline = settings.snapshot()
        baseline.shortcuts = ShortcutSet(shortcuts: [Shortcut(id: "deploy", label: "deploy", payload: .literal("SECRET=old"), order: 10)])
        baseline.sessionProfiles = [host: SessionProfile(terminalType: "xterm-256color", columns: 80, rows: 24, keepaliveSeconds: 30, jumpHosts: [JumpHop(hostname: "jump.example", port: 22, username: "ops")])]
        try settings.apply(SettingsImportProposal(snapshot: baseline, changes: [], securityReductions: [], sourceSchemaVersion: SettingsSnapshot.currentSchemaVersion, migrationNotes: []), confirmSecurityReductions: true)
        var snapshot = settings.snapshot()
        snapshot.shortcuts = ShortcutSet(shortcuts: [Shortcut(id: "deploy", label: "deploy", payload: .literal("SECRET=new"), order: 10)])
        snapshot.sessionProfiles = [host: SessionProfile(terminalType: "xterm-256color", columns: 120, rows: 40, keepaliveSeconds: 60, jumpHosts: [JumpHop(hostname: "jump2.example", port: 2222, username: "ops")])]

        let proposal = try SettingsImportProposal.parse(try JSONEncoder.openPawSettings.encode(snapshot), current: settings)

        let shortcutChange = try XCTUnwrap(proposal.changes.first { $0.controlID == "shortcut.deploy" })
        XCTAssertFalse(shortcutChange.oldDisplayValue.contains("SECRET"))
        XCTAssertFalse(shortcutChange.newDisplayValue.contains("SECRET"))
        XCTAssertNotEqual(shortcutChange.oldDisplayValue, shortcutChange.newDisplayValue)
        let profileChange = try XCTUnwrap(proposal.changes.first { $0.controlID == "session-profile.\(host)" })
        XCTAssertTrue(profileChange.newDisplayValue.contains("geometry:120x40"))
        XCTAssertTrue(profileChange.newDisplayValue.contains("keepalive:60"))
        XCTAssertFalse(profileChange.newDisplayValue.contains("jump2.example"))
    }

    func testImportRejectsInvalidSessionProfileValues() throws {
        let settings = OpenPawSettings(defaults: defaults())
        let host = UUID().uuidString
        let invalidProfiles = [
            SessionProfile(terminalType: "", columns: 80, rows: 24),
            SessionProfile(terminalType: "xterm\u{0000}", columns: 80, rows: 24),
            SessionProfile(terminalType: "xterm-256color", columns: 10, rows: 24),
            SessionProfile(terminalType: "xterm-256color", columns: 80, rows: 2),
            SessionProfile(terminalType: "xterm-256color", columns: 80, rows: 24, keepaliveSeconds: 9_999),
            SessionProfile(terminalType: "xterm-256color", columns: 80, rows: 24, jumpHosts: [JumpHop(hostname: "bad host", port: 22, username: "ops")]),
            SessionProfile(terminalType: "xterm-256color", columns: 80, rows: 24, jumpHosts: [JumpHop(hostname: "jump.example", port: 0, username: "ops")]),
            SessionProfile(terminalType: "xterm-256color", columns: 80, rows: 24, jumpHosts: [JumpHop(hostname: "jump.example", port: 22, username: "bad user")]),
            SessionProfile(terminalType: "xterm-256color", columns: 80, rows: 24, jumpHosts: Array(repeating: JumpHop(hostname: "jump.example", port: 22, username: "ops"), count: 9)),
        ]
        for profile in invalidProfiles {
            var snapshot = settings.snapshot()
            snapshot.sessionProfiles = [host: profile]
            XCTAssertThrowsError(try SettingsImportProposal.parse(try JSONEncoder.openPawSettings.encode(snapshot), current: settings))
        }
    }

    func testProposalApplyRevalidatesBeforeMutating() throws {
        let settings = OpenPawSettings(defaults: defaults())
        let original = settings.snapshot()
        var invalid = original
        invalid.previewPort = 0
        let proposal = SettingsImportProposal(snapshot: invalid, changes: [], securityReductions: [], sourceSchemaVersion: SettingsSnapshot.currentSchemaVersion, migrationNotes: [])
        XCTAssertThrowsError(try settings.apply(proposal, confirmSecurityReductions: true))
        XCTAssertEqual(settings.snapshot(), original)
    }

    func testResetProposalPreservesUnrelatedCategoriesAndAppliesAfterValidation() throws {
        let settings = OpenPawSettings(defaults: defaults())
        settings.previewPort = 8080
        settings.dictationMode = .terminal
        settings.terminalFontSize = 20
        let proposal = try SettingsImportProposal.reset(.appearanceAndTerminal, current: settings)
        try settings.apply(proposal, confirmSecurityReductions: true)
        XCTAssertEqual(settings.previewPort, 8080)
        XCTAssertEqual(settings.dictationMode, .terminal)
        XCTAssertEqual(settings.terminalFontSize, 13)
    }

    func testAllSettingsResetIsAProposalAndKeepsExternalHostMaterialOutOfScope() throws {
        let settings = OpenPawSettings(defaults: defaults())
        settings.previewPort = 8080
        settings.dictationMode = .terminal
        settings.terminalFontSize = 20
        settings.requiresBiometricGate = false
        let beforeApply = settings.snapshot()

        let proposal = try SettingsImportProposal.reset(.dataAll, current: settings)

        XCTAssertEqual(settings.snapshot(), beforeApply)
        XCTAssertTrue(proposal.changes.contains { $0.controlID == "preview-port" })
        XCTAssertTrue(proposal.changes.contains { $0.controlID == "dictation-destination" })
        XCTAssertTrue(proposal.changes.contains { $0.controlID == "terminal-font-size" })
        XCTAssertFalse(proposal.changes.contains { $0.controlID.contains("host") || $0.controlID.contains("keychain") })
        try settings.apply(proposal, confirmSecurityReductions: false)
        XCTAssertEqual(settings.previewPort, 3_000)
        XCTAssertEqual(settings.terminalFontSize, 13)
        XCTAssertTrue(settings.requiresBiometricGate)
    }

    func testRootViewUsesInjectedSettingsInstance() throws {
        let settings = OpenPawSettings(defaults: defaults())
        settings.scrollbackLines = 1_000
        let view = RootView(model: OpenPawModel(settings: settings), terminalSurface: { AnyView(EmptyView()) }, settings: settings)
        let reflected = Mirror(reflecting: view).children.first { $0.label == "settings" }?.value as? OpenPawSettings
        XCTAssertTrue(reflected === settings)
    }
}
