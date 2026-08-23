import Testing
@testable import OpenPawUI

@MainActor
@Suite("Settings navigation")
struct SettingsNavigationTests {
    @Test func categoryIDsAreStableAndComplete() {
        #expect(SettingsCategory.allCases.map(\.id) == [
            "appearance", "terminal", "voice", "connection", "sessions", "agents",
            "repositories", "security", "data", "diagnostics", "about",
        ])
        #expect(Set(SettingsCategory.allCases.map(\.id)).count == SettingsCategory.allCases.count)
    }

    @Test func searchKeywordsFindOwningCategoriesAndControls() {
        let results = SettingsSearchIndex.results(for: "face id")
        #expect(results.first?.category == .security)
        #expect(results.contains { $0.destination.controlID == "biometric-gate" })

        #expect(SettingsSearchIndex.results(for: "preview port").contains { $0.category == .connection && $0.destination.controlID == "preview-port" })
        #expect(SettingsSearchIndex.results(for: "event budget").contains { $0.category == .sessions && $0.destination.controlID == "event-budget" })
        #expect(SettingsSearchIndex.results(for: "github provider").contains { $0.category == .repositories })
    }

    @Test func everyDeclaredControlHasUniqueSearchRoute() {
        let destinations = Dictionary(grouping: SettingsSearchIndex.entries.compactMap(\.destination.controlID), by: { $0 })
        for control in SettingsControl.allCases {
            #expect(destinations[control.id]?.count == 1, "Missing or duplicate search owner for \(control.id)")
        }
    }

    @Test func searchRoutesControlsToTheirOwningCategory() {
        let owners: [SettingsControl: SettingsCategory] = [
            .terminalGround: .appearance,
            .biometricGate: .security,
            .dictationLanguage: .voice,
            .dictationRecogniser: .voice,
            .dictationDestination: .voice,
            .terminalCellSize: .terminal,
            .cursorKeys: .terminal,
            .shortcutBar: .terminal,
            .scrollback: .terminal,
            .previewPort: .connection,
            .manageHosts: .connection,
            .diagnostics: .connection,
            .eventBudget: .sessions,
            .exportJSON: .data,
            .importJSON: .data,
        ]
        for (control, category) in owners {
            let entry = SettingsSearchIndex.entries.first { $0.destination.controlID == control.id }
            #expect(entry?.destination.category == category)
        }
    }

    @Test func deepLinkDestinationsResolveToCategoryAndControl() {
        #expect(SettingsDestination(categoryID: "security", controlID: "biometric-gate")?.category == .security)
        #expect(SettingsDestination(categoryID: "sessions", controlID: "event-budget")?.controlID == "event-budget")
        #expect(SettingsDestination(categoryID: "missing", controlID: nil) == nil)
    }

    @Test func presentationPolicyMatchesDeviceClass() {
        #expect(SettingsPresentationPolicy.presentation(horizontalSizeClass: .compact) == .stack)
        #expect(SettingsPresentationPolicy.presentation(horizontalSizeClass: .regular) == .split)
        #expect(SettingsPresentationPolicy.presentation(horizontalSizeClass: nil) == .stack)
    }

    @Test func selectionPolicyPreservesNewestSearchControl() {
        let first = SettingsDestination(category: .security, controlID: SettingsControl.biometricGate.id)
        let newer = SettingsDestination(category: .voice, controlID: SettingsControl.dictationDestination.id)

        #expect(SettingsSelectionPolicy.defaultDestination == SettingsDestination(category: .security))
        #expect(SettingsSelectionPolicy.selection(afterSelecting: first) == first)
        #expect(SettingsSelectionPolicy.selection(afterSelecting: newer) == newer)
    }

    @Test func accessibilityIdentifiersAreStable() {
        #expect(SettingsCategory.security.accessibilityIdentifier == "settings.category.security")
        #expect(SettingsControl.biometricGate.accessibilityIdentifier == "settings.control.biometric-gate")
        #expect(SettingsControl.eventBudget.accessibilityIdentifier == "settings.control.event-budget")
        #expect(SettingsControl.previewPort.accessibilityIdentifier == "settings.control.preview-port")
    }
}
