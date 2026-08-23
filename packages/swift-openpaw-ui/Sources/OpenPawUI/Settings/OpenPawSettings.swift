import Foundation
import OpenPawProtocol
import OpenPawTerminalCore
import SwiftUI

/// Terminal grounds, built from theme tokens rather than a second palette.
public enum TerminalTheme: String, Codable, Sendable, Hashable, CaseIterable {
    case slate
    case well
    case warm

    public var displayName: String {
        switch self { case .slate: "Slate"; case .well: "Deep"; case .warm: "Warm" }
    }

    public var background: Color {
        switch self { case .slate: OpenPawTheme.ink; case .well: OpenPawTheme.well; case .warm: OpenPawTheme.panelWarm }
    }
    public var foreground: Color { OpenPawTheme.textPrimary }
}

@MainActor
@Observable
public final class OpenPawSettings {
    public static let fontSizeRange: ClosedRange<CGFloat> = 9...28
    public static let scrollbackChoices = [1_000, 5_000, 10_000, 25_000, 50_000]
    public static let eventBudgetChoices = [500, 2_000, 5_000, 10_000]
    public static let eventBudgetRange = 1...50_000
    public static let defaultEventBudgetPerSession = 2_000
    public static let defaultBiometricGraceInterval: TimeInterval = 120
    public static func clamp(fontSize: CGFloat) -> CGFloat { min(max(fontSize.rounded(), fontSizeRange.lowerBound), fontSizeRange.upperBound) }

    @ObservationIgnored private let defaults: UserDefaults

    public var requiresBiometricGate: Bool { didSet { defaults.set(requiresBiometricGate, forKey: Key.biometricGate) } }
    public var biometricGraceInterval: TimeInterval { didSet { let value = Self.sanitizedGraceInterval(biometricGraceInterval); if biometricGraceInterval != value { biometricGraceInterval = value; return }; defaults.set(biometricGraceInterval, forKey: Key.biometricGraceInterval) } }
    public var eventBudgetPerSession: Int { didSet { let value = Self.validatedEventBudget(eventBudgetPerSession); if eventBudgetPerSession != value { eventBudgetPerSession = value; return }; defaults.set(eventBudgetPerSession, forKey: Key.eventBudget) } }
    public var dictationLocaleID: String { didSet { defaults.set(dictationLocaleID, forKey: Key.dictationLocale) } }
    public var dictationMode: DictationMode { didSet { defaults.set(dictationMode.rawValue, forKey: Key.dictationMode) } }
    public var dictationEngine: DictationEngineChoice { didSet { defaults.set(dictationEngine.rawValue, forKey: Key.dictationEngine) } }
    public var terminalFontSize: CGFloat { didSet { let value = Self.clamp(fontSize: terminalFontSize); if terminalFontSize != value { terminalFontSize = value; return }; defaults.set(Double(terminalFontSize), forKey: Key.fontSize) } }
    public var terminalTheme: TerminalTheme { didSet { defaults.set(terminalTheme.rawValue, forKey: Key.theme) } }
    public var scrollbackLines: Int { didSet { let value = Self.sanitizedScrollback(scrollbackLines); if scrollbackLines != value { scrollbackLines = value; return }; defaults.set(scrollbackLines, forKey: Key.scrollback) } }
    public var applicationCursorKeys: Bool { didSet { defaults.set(applicationCursorKeys, forKey: Key.applicationCursorKeys) } }
    public var isShortcutBarVisible: Bool { didSet { defaults.set(isShortcutBarVisible, forKey: Key.shortcutBar) } }
    public var previewPort: Int { didSet { let value = Self.sanitizedPort(previewPort); if previewPort != value { previewPort = value; return }; defaults.set(previewPort, forKey: Key.previewPort) } }
    public var shortcuts: ShortcutSet { didSet { persist(shortcuts, forKey: Key.shortcuts) } }
    public private(set) var sessionProfiles: [String: SessionProfile] { didSet { persist(sessionProfiles, forKey: Key.profiles) } }

    enum Key {
        static let biometricGate = "openpaw.settings.biometricGate"
        static let biometricGraceInterval = "lock.graceInterval"
        static let eventBudget = "openpaw.settings.eventBudgetPerSession"
        static let dictationLocale = "openpaw.settings.dictationLocale"
        static let dictationMode = "openpaw.settings.dictationMode"
        static let dictationEngine = "openpaw.settings.dictationEngine"
        static let fontSize = "openpaw.settings.terminalFontSize"
        static let theme = "openpaw.settings.terminalTheme"
        static let scrollback = "openpaw.settings.scrollbackLines"
        static let applicationCursorKeys = "openpaw.settings.applicationCursorKeys"
        static let shortcutBar = "openpaw.settings.shortcutBarVisible"
        static let previewPort = "openpaw.settings.previewPort"
        static let shortcuts = "openpaw.settings.shortcuts"
        static let profiles = "openpaw.settings.sessionProfiles"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        requiresBiometricGate = defaults.object(forKey: Key.biometricGate) as? Bool ?? true
        biometricGraceInterval = Self.sanitizedGraceInterval(defaults.object(forKey: Key.biometricGraceInterval) as? Double ?? Self.defaultBiometricGraceInterval)
        let storedBudget = defaults.integer(forKey: Key.eventBudget)
        eventBudgetPerSession = storedBudget > 0 ? Self.validatedEventBudget(storedBudget) : Self.defaultEventBudgetPerSession
        dictationLocaleID = VoiceLocaleChoices.normalize(defaults.string(forKey: Key.dictationLocale) ?? Locale.current.identifier)
        dictationMode = defaults.string(forKey: Key.dictationMode).flatMap(DictationMode.init(rawValue:)) ?? .composer
        dictationEngine = defaults.string(forKey: Key.dictationEngine).flatMap(DictationEngineChoice.init(rawValue:)) ?? .appleSpeech
        let storedSize = defaults.double(forKey: Key.fontSize)
        terminalFontSize = storedSize > 0 ? Self.clamp(fontSize: CGFloat(storedSize)) : 13
        terminalTheme = defaults.string(forKey: Key.theme).flatMap(TerminalTheme.init(rawValue:)) ?? .slate
        let storedScrollback = defaults.integer(forKey: Key.scrollback)
        scrollbackLines = Self.sanitizedScrollback(storedScrollback > 0 ? storedScrollback : 10_000)
        applicationCursorKeys = defaults.bool(forKey: Key.applicationCursorKeys)
        isShortcutBarVisible = defaults.object(forKey: Key.shortcutBar) as? Bool ?? true
        let storedPort = defaults.integer(forKey: Key.previewPort)
        previewPort = Self.sanitizedPort(storedPort > 0 ? storedPort : 3_000)
        shortcuts = Self.decode(ShortcutSet.self, from: defaults, key: Key.shortcuts) ?? .default
        sessionProfiles = Self.decode([String: SessionProfile].self, from: defaults, key: Key.profiles) ?? [:]
    }

    public var dictationLocale: Locale { Locale(identifier: dictationLocaleID) }
    public var effectiveDictationEngine: DictationEngineChoice { DictationEngineChoice.resolve(dictationEngine, forLocale: dictationLocaleID) }
    public static func dictationLocaleChoices(deviceLocale: String) -> [String] { VoiceLocaleChoices.choices(deviceLocale: deviceLocale) }
    public static func validatedEventBudget(_ value: Int) -> Int { min(max(value, eventBudgetRange.lowerBound), eventBudgetRange.upperBound) }
    public static func sanitizedPort(_ value: Int) -> Int { (1...65_535).contains(value) ? value : 3_000 }
    public static func sanitizedScrollback(_ value: Int) -> Int { scrollbackChoices.contains(value) ? value : 10_000 }
    public static func sanitizedGraceInterval(_ value: TimeInterval) -> TimeInterval { value.isFinite && value >= 0 && value <= 86_400 ? value : defaultBiometricGraceInterval }

    public func profile(for host: HostID) -> SessionProfile { sessionProfiles[host.uuidString] ?? SessionProfile() }
    public func setProfile(_ profile: SessionProfile, for host: HostID) { sessionProfiles[host.uuidString] = profile }
    public func recordConnection(to host: HostID, at date: Date = Date()) { var p = profile(for: host); p.lastConnectedAt = date; sessionProfiles[host.uuidString] = p }
    public func forgetProfile(for host: HostID) { sessionProfiles.removeValue(forKey: host.uuidString) }

    public func snapshot() -> SettingsSnapshot {
        SettingsSnapshot(requiresBiometricGate: requiresBiometricGate, dictationLocaleID: dictationLocaleID, dictationMode: dictationMode, dictationEngine: dictationEngine, terminalFontSize: Double(terminalFontSize), terminalTheme: terminalTheme, scrollbackLines: scrollbackLines, applicationCursorKeys: applicationCursorKeys, previewPort: previewPort, eventBudgetPerSession: eventBudgetPerSession, shortcuts: shortcuts, sessionProfiles: sessionProfiles, isShortcutBarVisible: isShortcutBarVisible, biometricGraceInterval: biometricGraceInterval)
    }

    func commit(_ snapshot: SettingsSnapshot) {
        requiresBiometricGate = snapshot.requiresBiometricGate
        dictationLocaleID = snapshot.dictationLocaleID
        dictationMode = snapshot.dictationMode
        dictationEngine = snapshot.dictationEngine
        terminalFontSize = Self.clamp(fontSize: CGFloat(snapshot.terminalFontSize))
        terminalTheme = snapshot.terminalTheme
        scrollbackLines = snapshot.scrollbackLines
        applicationCursorKeys = snapshot.applicationCursorKeys
        previewPort = snapshot.previewPort
        eventBudgetPerSession = snapshot.eventBudgetPerSession
        isShortcutBarVisible = snapshot.isShortcutBarVisible
        biometricGraceInterval = snapshot.biometricGraceInterval
        shortcuts = snapshot.shortcuts
        sessionProfiles = snapshot.sessionProfiles
    }

    public func apply(_ proposal: SettingsImportProposal, confirmSecurityReductions: Bool) throws {
        try SettingsImportProposal.validate(proposal.snapshot)
        if !proposal.securityReductions.isEmpty && !confirmSecurityReductions { throw SettingsValidationError.securityReductionRequiresConfirmation }
        commit(proposal.snapshot)
    }

    public static func preview() -> OpenPawSettings {
        let suite = "openpaw.previews"
        guard let store = UserDefaults(suiteName: suite) else {
            preconditionFailure("Could not create isolated preview defaults suite")
        }
        store.removePersistentDomain(forName: suite)
        let settings = OpenPawSettings(defaults: store)
        settings.shortcuts = ShortcutSet(shortcuts: ShortcutSet.default.shortcuts + [Shortcut(id: "gst", label: "gst", payload: .literal("git status\n"), order: 100), Shortcut(id: "clr", label: "clr", payload: .literal("clear\n"), order: 101)])
        return settings
    }

    private func persist<Value: Encodable>(_ value: Value, forKey key: String) { if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) } }
    private static func decode<Value: Decodable>(_ type: Value.Type, from defaults: UserDefaults, key: String) -> Value? { guard let data = defaults.data(forKey: key) else { return nil }; return try? JSONDecoder().decode(type, from: data) }
}
