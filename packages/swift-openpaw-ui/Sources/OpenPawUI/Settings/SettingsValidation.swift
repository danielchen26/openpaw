import Foundation
import OpenPawTerminalCore

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
    public static func reset(_ category: SettingsResetCategory, current settings: OpenPawSettings) throws -> SettingsImportProposal {
        let suite = "openpaw.settings.reset.defaults.\(UUID().uuidString)"
        guard let store = UserDefaults(suiteName: suite) else {
            throw SettingsValidationError.invalidValue("reset defaults suite")
        }
        store.removePersistentDomain(forName: suite)
        defer { store.removePersistentDomain(forName: suite) }
        let baseline = OpenPawSettings(defaults: store).snapshot()
        var snapshot = settings.snapshot()
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
        try validate(snapshot)
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

        let oldShortcuts = Dictionary(uniqueKeysWithValues: old.shortcuts.shortcuts.map { ($0.id, $0) })
        let newShortcuts = Dictionary(uniqueKeysWithValues: snapshot.shortcuts.shortcuts.map { ($0.id, $0) })
        for id in Set(oldShortcuts.keys).union(newShortcuts.keys).sorted() {
            guard oldShortcuts[id] != newShortcuts[id] else { continue }
            let values = changedDisplay(old: oldShortcuts[id].map(shortcutDisplay) ?? "absent", new: newShortcuts[id].map(shortcutDisplay) ?? "absent")
            changes.append(SettingsChange(category: .appearanceAndTerminal, controlID: "shortcut.\(id)", oldDisplayValue: values.old, newDisplayValue: values.new, securityImpact: nil))
        }

        let oldProfiles = old.sessionProfiles
        let newProfiles = snapshot.sessionProfiles
        for id in Set(oldProfiles.keys).union(newProfiles.keys).sorted() {
            guard oldProfiles[id] != newProfiles[id] else { continue }
            let values = changedDisplay(old: oldProfiles[id].map(profileDisplay) ?? "absent", new: newProfiles[id].map(profileDisplay) ?? "absent")
            changes.append(SettingsChange(category: .sessionsAndBudgets, controlID: "session-profile.\(id)", oldDisplayValue: values.old, newDisplayValue: values.new, securityImpact: nil))
        }

        changes.sort { ($0.category.rawValue, $0.controlID) < ($1.category.rawValue, $1.controlID) }
        return SettingsImportProposal(snapshot: snapshot, changes: changes, securityReductions: changes.compactMap(\.securityImpact), sourceSchemaVersion: snapshot.schemaVersion, migrationNotes: migrationNotes)
    }

    @MainActor
    static func validate(_ snapshot: SettingsSnapshot) throws {
        guard OpenPawSettings.eventBudgetRange.contains(snapshot.eventBudgetPerSession) else { throw SettingsValidationError.invalidValue("eventBudgetPerSession") }
        guard (1...65_535).contains(snapshot.previewPort) else { throw SettingsValidationError.invalidValue("previewPort") }
        guard snapshot.terminalFontSize.isFinite, OpenPawSettings.fontSizeRange.contains(CGFloat(snapshot.terminalFontSize)) else { throw SettingsValidationError.invalidValue("terminalFontSize") }
        guard snapshot.biometricGraceInterval.isFinite, snapshot.biometricGraceInterval >= 0, snapshot.biometricGraceInterval <= 86_400 else { throw SettingsValidationError.invalidValue("biometricGraceInterval") }
        guard OpenPawSettings.scrollbackChoices.contains(snapshot.scrollbackLines) else { throw SettingsValidationError.invalidValue("scrollbackLines") }
        for (key, profile) in snapshot.sessionProfiles {
            try validateHostID(key)
            try validate(profile: profile)
        }
        for shortcut in snapshot.shortcuts.shortcuts { try validateShortcutID(shortcut.id) }
    }

    private static func validate(profile: SessionProfile) throws {
        guard !profile.terminalType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !profile.terminalType.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            profile.terminalType.count <= 64
        else { throw SettingsValidationError.invalidValue("sessionProfiles.terminalType") }
        guard HostDraft.columnRange.contains(profile.columns), HostDraft.rowRange.contains(profile.rows) else { throw SettingsValidationError.invalidValue("sessionProfiles.geometry") }
        guard HostDraft.keepaliveRange.contains(profile.keepaliveSeconds) else { throw SettingsValidationError.invalidValue("sessionProfiles.keepalive") }
        guard profile.jumpHosts.count <= 8 else { throw SettingsValidationError.invalidValue("sessionProfiles.jumpHosts") }
        for hop in profile.jumpHosts {
            let host = hop.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
            let user = hop.username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty, host.count <= 255, !host.contains(where: \.isWhitespace), !host.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw SettingsValidationError.invalidValue("sessionProfiles.jumpHost.hostname") }
            guard HostDraft.portRange.contains(hop.port) else { throw SettingsValidationError.invalidValue("sessionProfiles.jumpHost.port") }
            guard user.count <= 128, !user.contains(where: \.isWhitespace), !user.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw SettingsValidationError.invalidValue("sessionProfiles.jumpHost.username") }
        }
    }

    private static func validateHostID(_ value: String) throws {
        guard UUID(uuidString: value)?.uuidString.uppercased() == value.uppercased() else { throw SettingsValidationError.invalidValue("sessionProfiles") }
    }

    private static func validateShortcutID(_ value: String) throws {
        guard (1...64).contains(value.count), value != ".", value != ".." else { throw SettingsValidationError.invalidValue("shortcuts") }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { throw SettingsValidationError.invalidValue("shortcuts") }
    }

    private static func shortcutDisplay(_ shortcut: Shortcut) -> String {
        let kind: String
        switch shortcut.payload {
        case .literal: kind = "literal"
        case .chord: kind = "chord"
        case .modifierLatch: kind = "modifier"
        }
        return "\(shortcut.label)|\(kind)|order:\(shortcut.order)|payload:redacted"
    }

    private static func profileDisplay(_ profile: SessionProfile) -> String {
        var parts = ["profile", "geometry:\(profile.columns)x\(profile.rows)", "term:\(redactedToken(profile.terminalType))", "keepalive:\(profile.keepaliveSeconds)", "jumps:\(profile.jumpHosts.count)"]
        if profile.lastConnectedAt != nil { parts.append("lastConnectedAt:set") }
        return parts.joined(separator: "|")
    }

    private static func redactedToken(_ value: String) -> String { value.isEmpty ? "empty" : "set" }

    private static func display<T>(_ value: T) -> String { String(describing: value) }

    private static func changedDisplay(old: String, new: String) -> (old: String, new: String) {
        old == new ? (old, "\(new)|changed") : (old, new)
    }
}
