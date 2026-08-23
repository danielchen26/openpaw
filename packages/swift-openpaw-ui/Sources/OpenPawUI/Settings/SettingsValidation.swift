import Foundation

public enum SettingsValidationError: Error, Equatable, CustomStringConvertible {
    case futureSchemaVersion(Int)
    case invalidValue(String)
    case securityReductionRequiresConfirmation

    public var description: String {
        switch self {
        case .futureSchemaVersion(let version): "settings schema version \(version) is newer than this app"
        case .invalidValue(let field): "invalid settings value: \(field)"
        case .securityReductionRequiresConfirmation: "security reductions require explicit confirmation"
        }
    }
}

public enum SettingsResetCategory: String, Sendable, Hashable, CaseIterable {
    case appearanceAndTerminal
    case voice
    case connections
    case sessionsAndBudgets
    case security
    case dataAll
}

public enum SettingsSecurityReduction: String, Sendable, Hashable, Codable {
    case biometricProtectionDisabled
}

public struct SettingsChange: Sendable, Hashable {
    public var category: SettingsResetCategory
    public var controlID: String
    public var oldDisplayValue: String
    public var newDisplayValue: String
    public var securityImpact: SettingsSecurityReduction?
}

public struct SettingsImportProposal: Sendable, Hashable {
    public var snapshot: SettingsSnapshot
    public var changes: [SettingsChange]
    public var securityReductions: [SettingsSecurityReduction]
    public var sourceSchemaVersion: Int
    public var migrationNotes: [String]

    @MainActor
    public static func parse(_ data: Data, current settings: OpenPawSettings) throws -> SettingsImportProposal {
        let snapshot = try JSONDecoder().decode(SettingsSnapshot.self, from: data)
        try validate(snapshot)
        return proposal(snapshot: snapshot, current: settings, migrationNotes: snapshot.schemaVersion < SettingsSnapshot.currentSchemaVersion ? ["Migrated settings schema \(snapshot.schemaVersion) to \(SettingsSnapshot.currentSchemaVersion)."] : [])
    }

    @MainActor
    public static func reset(_ category: SettingsResetCategory, current settings: OpenPawSettings) -> SettingsImportProposal {
        let defaults = OpenPawSettings(defaults: UserDefaults(suiteName: "openpaw.settings.reset.defaults.\(UUID().uuidString)") ?? .standard)
        var snapshot = settings.snapshot()
        let baseline = defaults.snapshot()
        switch category {
        case .appearanceAndTerminal:
            snapshot.terminalFontSize = baseline.terminalFontSize
            snapshot.terminalTheme = baseline.terminalTheme
            snapshot.scrollbackLines = baseline.scrollbackLines
            snapshot.applicationCursorKeys = baseline.applicationCursorKeys
            snapshot.isShortcutBarVisible = baseline.isShortcutBarVisible
            snapshot.shortcuts = baseline.shortcuts
        case .voice:
            snapshot.dictationLocaleID = baseline.dictationLocaleID
            snapshot.dictationMode = baseline.dictationMode
            snapshot.dictationEngine = baseline.dictationEngine
        case .connections:
            snapshot.previewPort = baseline.previewPort
        case .sessionsAndBudgets:
            snapshot.eventBudgetPerSession = baseline.eventBudgetPerSession
            snapshot.sessionProfiles = baseline.sessionProfiles
        case .security:
            snapshot.requiresBiometricGate = baseline.requiresBiometricGate
            snapshot.biometricGraceInterval = baseline.biometricGraceInterval
        case .dataAll:
            snapshot = baseline
        }
        return proposal(snapshot: snapshot, current: settings, migrationNotes: ["Reset \(category.rawValue) settings to defaults."])
    }

    @MainActor
    private static func proposal(snapshot: SettingsSnapshot, current settings: OpenPawSettings, migrationNotes: [String]) -> SettingsImportProposal {
        let old = settings.snapshot()
        var changes: [SettingsChange] = []
        func append(_ category: SettingsResetCategory, _ id: String, _ oldValue: String, _ newValue: String, _ impact: SettingsSecurityReduction? = nil) {
            guard oldValue != newValue else { return }
            changes.append(SettingsChange(category: category, controlID: id, oldDisplayValue: oldValue, newDisplayValue: newValue, securityImpact: impact))
        }
        append(.security, "biometric-gate", String(old.requiresBiometricGate), String(snapshot.requiresBiometricGate), old.requiresBiometricGate && !snapshot.requiresBiometricGate ? .biometricProtectionDisabled : nil)
        append(.security, "biometric-grace-interval", display(old.biometricGraceInterval), display(snapshot.biometricGraceInterval))
        append(.voice, "dictation-language", old.dictationLocaleID, snapshot.dictationLocaleID)
        append(.voice, "dictation-destination", old.dictationMode.rawValue, snapshot.dictationMode.rawValue)
        append(.voice, "dictation-recogniser", old.dictationEngine.rawValue, snapshot.dictationEngine.rawValue)
        append(.appearanceAndTerminal, "terminal-font-size", display(old.terminalFontSize), display(snapshot.terminalFontSize))
        append(.appearanceAndTerminal, "terminal-theme", old.terminalTheme.rawValue, snapshot.terminalTheme.rawValue)
        append(.appearanceAndTerminal, "scrollback-lines", String(old.scrollbackLines), String(snapshot.scrollbackLines))
        append(.appearanceAndTerminal, "application-cursor-keys", String(old.applicationCursorKeys), String(snapshot.applicationCursorKeys))
        append(.appearanceAndTerminal, "shortcut-bar-visible", String(old.isShortcutBarVisible), String(snapshot.isShortcutBarVisible))
        append(.connections, "preview-port", String(old.previewPort), String(snapshot.previewPort))
        append(.sessionsAndBudgets, "event-budget", String(old.eventBudgetPerSession), String(snapshot.eventBudgetPerSession))
        changes.sort { $0.controlID < $1.controlID }
        return SettingsImportProposal(snapshot: snapshot, changes: changes, securityReductions: changes.compactMap(\.securityImpact), sourceSchemaVersion: snapshot.schemaVersion, migrationNotes: migrationNotes)
    }

    @MainActor
    private static func validate(_ snapshot: SettingsSnapshot) throws {
        guard OpenPawSettings.eventBudgetRange.contains(snapshot.eventBudgetPerSession) else { throw SettingsValidationError.invalidValue("eventBudgetPerSession") }
        guard (1...65_535).contains(snapshot.previewPort) else { throw SettingsValidationError.invalidValue("previewPort") }
        guard snapshot.terminalFontSize.isFinite, OpenPawSettings.fontSizeRange.contains(CGFloat(snapshot.terminalFontSize)) else { throw SettingsValidationError.invalidValue("terminalFontSize") }
        guard snapshot.biometricGraceInterval.isFinite, snapshot.biometricGraceInterval >= 0, snapshot.biometricGraceInterval <= 86_400 else { throw SettingsValidationError.invalidValue("biometricGraceInterval") }
        guard OpenPawSettings.scrollbackChoices.contains(snapshot.scrollbackLines) else { throw SettingsValidationError.invalidValue("scrollbackLines") }
        for key in snapshot.sessionProfiles.keys { try validateIdentifier(key, field: "sessionProfiles") }
        for shortcut in snapshot.shortcuts.shortcuts { try validateIdentifier(shortcut.id, field: "shortcuts") }
    }

    private static func validateIdentifier(_ value: String, field: String) throws {
        guard !value.isEmpty, value.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:\0\n\r\t")) == nil, value.rangeOfCharacter(from: .controlCharacters) == nil else { throw SettingsValidationError.invalidValue(field) }
    }

    private static func display<T>(_ value: T) -> String { String(describing: value) }
}
