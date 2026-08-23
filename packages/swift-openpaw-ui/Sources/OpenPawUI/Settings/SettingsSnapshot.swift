import Foundation
import OpenPawProtocol
import OpenPawTerminalCore

public struct SettingsSnapshot: Codable, Sendable, Hashable {
    public static let currentSchemaVersion = 2
    public var schemaVersion: Int
    public var requiresBiometricGate: Bool
    public var dictationLocaleID: String
    public var dictationMode: DictationMode
    public var dictationEngine: DictationEngineChoice
    public var terminalFontSize: Double
    public var terminalTheme: TerminalTheme
    public var scrollbackLines: Int
    public var applicationCursorKeys: Bool
    public var previewPort: Int
    public var eventBudgetPerSession: Int
    public var shortcuts: ShortcutSet
    public var sessionProfiles: [String: SessionProfile]
    public var isShortcutBarVisible: Bool
    public var biometricGraceInterval: TimeInterval

    public init(requiresBiometricGate: Bool, dictationLocaleID: String, dictationMode: DictationMode, dictationEngine: DictationEngineChoice = .appleSpeech, terminalFontSize: Double, terminalTheme: TerminalTheme, scrollbackLines: Int, applicationCursorKeys: Bool, previewPort: Int, eventBudgetPerSession: Int, shortcuts: ShortcutSet, sessionProfiles: [String: SessionProfile], isShortcutBarVisible: Bool = true, biometricGraceInterval: TimeInterval = 120, schemaVersion: Int = Self.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.requiresBiometricGate = requiresBiometricGate
        self.dictationLocaleID = dictationLocaleID
        self.dictationMode = dictationMode
        self.dictationEngine = dictationEngine
        self.terminalFontSize = terminalFontSize
        self.terminalTheme = terminalTheme
        self.scrollbackLines = scrollbackLines
        self.applicationCursorKeys = applicationCursorKeys
        self.previewPort = previewPort
        self.eventBudgetPerSession = eventBudgetPerSession
        self.shortcuts = shortcuts
        self.sessionProfiles = sessionProfiles
        self.isShortcutBarVisible = isShortcutBarVisible
        self.biometricGraceInterval = biometricGraceInterval
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case requiresBiometricGate = "requires_biometric_gate"
        case dictationLocaleID = "dictation_locale"
        case dictationMode = "dictation_mode"
        case dictationEngine = "dictation_engine"
        case terminalFontSize = "terminal_font_size"
        case terminalTheme = "terminal_theme"
        case scrollbackLines = "scrollback_lines"
        case applicationCursorKeys = "application_cursor_keys"
        case previewPort = "preview_port"
        case eventBudgetPerSession = "event_budget_per_session"
        case shortcuts
        case sessionProfiles = "session_profiles"
        case isShortcutBarVisible = "shortcut_bar_visible"
        case biometricGraceInterval = "biometric_grace_interval"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        if schemaVersion > Self.currentSchemaVersion { throw SettingsValidationError.futureSchemaVersion(schemaVersion) }
        requiresBiometricGate = try c.decodeIfPresent(Bool.self, forKey: .requiresBiometricGate) ?? true
        dictationLocaleID = try c.decodeIfPresent(String.self, forKey: .dictationLocaleID) ?? Locale.current.identifier
        dictationMode = try c.decodeIfPresent(DictationMode.self, forKey: .dictationMode) ?? .composer
        dictationEngine = try c.decodeIfPresent(DictationEngineChoice.self, forKey: .dictationEngine) ?? .appleSpeech
        terminalFontSize = try c.decodeIfPresent(Double.self, forKey: .terminalFontSize) ?? 13
        terminalTheme = try c.decodeIfPresent(TerminalTheme.self, forKey: .terminalTheme) ?? .slate
        scrollbackLines = try c.decodeIfPresent(Int.self, forKey: .scrollbackLines) ?? 10_000
        applicationCursorKeys = try c.decodeIfPresent(Bool.self, forKey: .applicationCursorKeys) ?? false
        previewPort = try c.decodeIfPresent(Int.self, forKey: .previewPort) ?? 3_000
        eventBudgetPerSession = try c.decodeIfPresent(Int.self, forKey: .eventBudgetPerSession) ?? 2_000
        shortcuts = try c.decodeIfPresent(ShortcutSet.self, forKey: .shortcuts) ?? .default
        sessionProfiles = try c.decodeIfPresent([String: SessionProfile].self, forKey: .sessionProfiles) ?? [:]
        isShortcutBarVisible = try c.decodeIfPresent(Bool.self, forKey: .isShortcutBarVisible) ?? true
        biometricGraceInterval = try c.decodeIfPresent(Double.self, forKey: .biometricGraceInterval) ?? 120
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try c.encode(requiresBiometricGate, forKey: .requiresBiometricGate)
        try c.encode(dictationLocaleID, forKey: .dictationLocaleID)
        try c.encode(dictationMode, forKey: .dictationMode)
        try c.encode(dictationEngine, forKey: .dictationEngine)
        try c.encode(terminalFontSize, forKey: .terminalFontSize)
        try c.encode(terminalTheme, forKey: .terminalTheme)
        try c.encode(scrollbackLines, forKey: .scrollbackLines)
        try c.encode(applicationCursorKeys, forKey: .applicationCursorKeys)
        try c.encode(previewPort, forKey: .previewPort)
        try c.encode(eventBudgetPerSession, forKey: .eventBudgetPerSession)
        try c.encode(shortcuts, forKey: .shortcuts)
        try c.encode(sessionProfiles, forKey: .sessionProfiles)
        try c.encode(isShortcutBarVisible, forKey: .isShortcutBarVisible)
        try c.encode(biometricGraceInterval, forKey: .biometricGraceInterval)
    }
}

public extension JSONEncoder {
    static var openPawSettings: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }
}
