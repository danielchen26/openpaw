import Foundation
import OpenPawProtocol
import OpenPawTerminalCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Terminal theme

/// Terminal grounds, built from theme tokens rather than a second palette. Three, because a terminal needs a
/// ground and a temperature, not a gallery of skins nobody can tell apart in a screenshot.
public enum TerminalTheme: String, Codable, Sendable, Hashable, CaseIterable {
    /// The app's own slate. Matches the chrome exactly.
    case slate
    /// The deepest well. Highest contrast for code and diffs.
    case well
    /// Warm ground, for people who read prose in the terminal all day.
    case warm

    public var displayName: String {
        switch self {
        case .slate: "Slate"
        case .well: "Deep"
        case .warm: "Warm"
        }
    }

    public var background: Color {
        switch self {
        case .slate: OpenPawTheme.ink
        case .well: OpenPawTheme.well
        case .warm: OpenPawTheme.panelWarm
        }
    }

    public var foreground: Color { OpenPawTheme.textPrimary }
}

// MARK: - Settings

/// Device-local preferences.
///
/// These belong to the device, not the host: a phone with a small screen wants a different cell size and terminal
/// geometry than an iPad on a desk, and neither should push its taste to the other. Nothing here is a secret, so
/// `UserDefaults` is the right store; keys are namespaced so an app-level default cannot collide.
@MainActor
@Observable
public final class OpenPawSettings {
    /// Terminal cell size in points. Deliberately *not* a Dynamic Type token: a terminal's cell grid is a fixed
    /// measure that the user sets directly with the stepper or a pinch, and scaling it with the content size
    /// category would reflow the remote program's own layout.
    public static let fontSizeRange: ClosedRange<CGFloat> = 9...28
    public static let scrollbackChoices = [1_000, 5_000, 10_000, 25_000, 50_000]
    public static let eventBudgetChoices = [500, 2_000, 5_000, 10_000]

    @ObservationIgnored private let defaults: UserDefaults

    public var requiresBiometricGate: Bool {
        didSet { defaults.set(requiresBiometricGate, forKey: Key.biometricGate) }
    }
    public var dictationLocaleID: String {
        didSet { defaults.set(dictationLocaleID, forKey: Key.dictationLocale) }
    }
    public var dictationMode: DictationMode {
        didSet { defaults.set(dictationMode.rawValue, forKey: Key.dictationMode) }
    }
    public var terminalFontSize: CGFloat {
        didSet { defaults.set(Double(terminalFontSize), forKey: Key.fontSize) }
    }
    public var terminalTheme: TerminalTheme {
        didSet { defaults.set(terminalTheme.rawValue, forKey: Key.theme) }
    }
    public var scrollbackLines: Int {
        didSet { defaults.set(scrollbackLines, forKey: Key.scrollback) }
    }
    /// Sends `ESC O A` style cursor keys instead of `ESC [ A`. Full-screen programs ask for this mode; a shell
    /// does not. The wrong setting makes arrow keys print letters, which is worth one switch.
    public var applicationCursorKeys: Bool {
        didSet { defaults.set(applicationCursorKeys, forKey: Key.applicationCursorKeys) }
    }
    public var isShortcutBarVisible: Bool {
        didSet { defaults.set(isShortcutBarVisible, forKey: Key.shortcutBar) }
    }
    /// Port the repo preview proxies. Must be one the host is willing to forward.
    public var previewPort: Int {
        didSet { defaults.set(previewPort, forKey: Key.previewPort) }
    }
    public var shortcuts: ShortcutSet {
        didSet { persist(shortcuts, forKey: Key.shortcuts) }
    }
    /// Per-host session mechanics, keyed by `HostID`. Kept out of `HostStore` on purpose: the exportable host list
    /// is the shared identity of a machine, and terminal geometry is this device's business.
    public private(set) var sessionProfiles: [String: SessionProfile] {
        didSet { persist(sessionProfiles, forKey: Key.profiles) }
    }

    private enum Key {
        static let biometricGate = "openpaw.settings.biometricGate"
        static let dictationLocale = "openpaw.settings.dictationLocale"
        static let dictationMode = "openpaw.settings.dictationMode"
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
        // Absent means on, matching the lock itself: `bool(forKey:)` reports false for a key that was never written,
        // which would show the switch off while the app was in fact locking on every launch.
        requiresBiometricGate = defaults.object(forKey: Key.biometricGate) as? Bool ?? true
        dictationLocaleID = defaults.string(forKey: Key.dictationLocale) ?? Locale.current.identifier
        dictationMode =
            defaults.string(forKey: Key.dictationMode).flatMap(DictationMode.init(rawValue:)) ?? .composer
        let storedSize = defaults.double(forKey: Key.fontSize)
        terminalFontSize = storedSize > 0 ? CGFloat(storedSize) : 13
        terminalTheme = defaults.string(forKey: Key.theme).flatMap(TerminalTheme.init(rawValue:)) ?? .slate
        let storedScrollback = defaults.integer(forKey: Key.scrollback)
        scrollbackLines = storedScrollback > 0 ? storedScrollback : 10_000
        applicationCursorKeys = defaults.bool(forKey: Key.applicationCursorKeys)
        // Visible unless the user turns it off: a terminal on a touch keyboard with no escape key is a demo.
        isShortcutBarVisible = defaults.object(forKey: Key.shortcutBar) as? Bool ?? true
        let storedPort = defaults.integer(forKey: Key.previewPort)
        previewPort = storedPort > 0 ? storedPort : 3_000
        shortcuts = Self.decode(ShortcutSet.self, from: defaults, key: Key.shortcuts) ?? .default
        sessionProfiles = Self.decode([String: SessionProfile].self, from: defaults, key: Key.profiles) ?? [:]
    }

    public var dictationLocale: Locale { Locale(identifier: dictationLocaleID) }

    public static func dictationLocaleChoices(deviceLocale: String) -> [String] {
        VoiceLocaleChoices.choices(deviceLocale: deviceLocale)
    }

    // MARK: Session profiles

    public func profile(for host: HostID) -> SessionProfile {
        sessionProfiles[host.uuidString] ?? SessionProfile()
    }

    public func setProfile(_ profile: SessionProfile, for host: HostID) {
        sessionProfiles[host.uuidString] = profile
    }

    /// Stamps a successful connection so the host list can say when this device last reached the machine.
    public func recordConnection(to host: HostID, at date: Date = Date()) {
        var updated = profile(for: host)
        updated.lastConnectedAt = date
        sessionProfiles[host.uuidString] = updated
    }

    public func forgetProfile(for host: HostID) {
        sessionProfiles.removeValue(forKey: host.uuidString)
    }

    // MARK: Transfer

    public func snapshot(eventBudget: Int) -> SettingsSnapshot {
        SettingsSnapshot(
            requiresBiometricGate: requiresBiometricGate,
            dictationLocaleID: dictationLocaleID,
            dictationMode: dictationMode,
            terminalFontSize: Double(terminalFontSize),
            terminalTheme: terminalTheme,
            scrollbackLines: scrollbackLines,
            applicationCursorKeys: applicationCursorKeys,
            previewPort: previewPort,
            eventBudgetPerSession: eventBudget,
            shortcuts: shortcuts,
            sessionProfiles: sessionProfiles
        )
    }

    /// Applies an imported snapshot. Returns the event budget so the caller can push it into the model, which owns
    /// that number.
    @discardableResult
    public func apply(_ snapshot: SettingsSnapshot) -> Int {
        requiresBiometricGate = snapshot.requiresBiometricGate
        dictationLocaleID = snapshot.dictationLocaleID
        dictationMode = snapshot.dictationMode
        terminalFontSize = min(
            max(CGFloat(snapshot.terminalFontSize), Self.fontSizeRange.lowerBound),
            Self.fontSizeRange.upperBound)
        terminalTheme = snapshot.terminalTheme
        scrollbackLines = snapshot.scrollbackLines
        applicationCursorKeys = snapshot.applicationCursorKeys
        previewPort = snapshot.previewPort
        shortcuts = snapshot.shortcuts
        sessionProfiles = snapshot.sessionProfiles
        return snapshot.eventBudgetPerSession
    }

    /// Volatile settings for previews and headless snapshot runs, so rendering never writes into the real defaults
    /// database.
    public static func preview() -> OpenPawSettings {
        let suite = "openpaw.previews"
        let store = UserDefaults(suiteName: suite) ?? .standard
        store.removePersistentDomain(forName: suite)
        let settings = OpenPawSettings(defaults: store)
        settings.shortcuts = ShortcutSet(
            shortcuts: ShortcutSet.default.shortcuts + [
                Shortcut(id: "gst", label: "gst", payload: .literal("git status\n"), order: 100),
                Shortcut(id: "clr", label: "clr", payload: .literal("clear\n"), order: 101),
            ])
        return settings
    }

    private func persist<Value: Encodable>(_ value: Value, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type, from defaults: UserDefaults, key: String
    ) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// The exportable form of everything on this screen.
public struct SettingsSnapshot: Codable, Sendable, Hashable {
    public var requiresBiometricGate: Bool
    public var dictationLocaleID: String
    public var dictationMode: DictationMode
    public var terminalFontSize: Double
    public var terminalTheme: TerminalTheme
    public var scrollbackLines: Int
    public var applicationCursorKeys: Bool
    public var previewPort: Int
    public var eventBudgetPerSession: Int
    public var shortcuts: ShortcutSet
    public var sessionProfiles: [String: SessionProfile]

    public init(
        requiresBiometricGate: Bool,
        dictationLocaleID: String,
        dictationMode: DictationMode,
        terminalFontSize: Double,
        terminalTheme: TerminalTheme,
        scrollbackLines: Int,
        applicationCursorKeys: Bool,
        previewPort: Int,
        eventBudgetPerSession: Int,
        shortcuts: ShortcutSet,
        sessionProfiles: [String: SessionProfile]
    ) {
        self.requiresBiometricGate = requiresBiometricGate
        self.dictationLocaleID = dictationLocaleID
        self.dictationMode = dictationMode
        self.terminalFontSize = terminalFontSize
        self.terminalTheme = terminalTheme
        self.scrollbackLines = scrollbackLines
        self.applicationCursorKeys = applicationCursorKeys
        self.previewPort = previewPort
        self.eventBudgetPerSession = eventBudgetPerSession
        self.shortcuts = shortcuts
        self.sessionProfiles = sessionProfiles
    }

    private enum CodingKeys: String, CodingKey {
        case requiresBiometricGate = "requires_biometric_gate"
        case dictationLocaleID = "dictation_locale"
        case dictationMode = "dictation_mode"
        case terminalFontSize = "terminal_font_size"
        case terminalTheme = "terminal_theme"
        case scrollbackLines = "scrollback_lines"
        case applicationCursorKeys = "application_cursor_keys"
        case previewPort = "preview_port"
        case eventBudgetPerSession = "event_budget_per_session"
        case shortcuts
        case sessionProfiles = "session_profiles"
    }
}

// MARK: - Paired devices

/// A device the host has seen, reconstructed from the audit log.
///
/// The host is the register of record, which is why this screen tells you to revoke there rather than pretending it
/// can do it from here.
public struct PairedDevice: Identifiable, Sendable, Hashable {
    public let id: String
    public let lastSeen: Date
    public let actions: Int

    public init(id: String, lastSeen: Date, actions: Int) {
        self.id = id
        self.lastSeen = lastSeen
        self.actions = actions
    }

    public static func derive(from entries: [AuditEntry]) -> [PairedDevice] {
        var lastSeen: [String: Date] = [:]
        var counts: [String: Int] = [:]
        for entry in entries {
            guard let device = entry.deviceID else { continue }
            counts[device, default: 0] += 1
            lastSeen[device] = lastSeen[device].map { max($0, entry.at) } ?? entry.at
        }
        return lastSeen
            .map { PairedDevice(id: $0.key, lastSeen: $0.value, actions: counts[$0.key] ?? 0) }
            .sorted { $0.lastSeen > $1.lastSeen }
    }
}

// MARK: - Settings screen

@MainActor
public struct SettingsView: View {
    private let model: OpenPawModel
    private let settings: OpenPawSettings

    @State private var devices: [PairedDevice] = []
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var exportDocument = ShellJSONDocument(data: Data())
    @State private var transferError: String?

    public init(model: OpenPawModel, settings: OpenPawSettings) {
        self.model = model
        self.settings = settings
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.large) {
                security
                dictation
                terminal
                budgets
                hostSection
                pairing
                configuration
                about
            }
            .padding(OpenPawTheme.Space.large)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .background(OpenPawTheme.ink)
        // System controls arrive tinted the platform accent, which is a saturated colour with no meaning here.
        // The risk ramp is the only saturated thing in OpenPaw, so selected segments and switches read as the
        // same near-white primary the buttons use.
        .tint(OpenPawTheme.textPrimary)
        .navigationTitle("Settings")
        .task { await loadDevices() }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "openpaw-settings"
        ) { result in
            if case .failure(let error) = result { transferError = String(describing: error) }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
            importSettings(from: result)
        }
    }

    // MARK: Security

    private var security: some View {
        Panel(label: "Security") {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
                Toggle(isOn: bind(\.requiresBiometricGate)) {
                    Text("Require Face ID to open OpenPaw")
                        .font(OpenPawTheme.Machine.body)
                        .foregroundStyle(OpenPawTheme.textPrimary)
                }
                .frame(minHeight: 44)
                Text(
                    """
                    The app asks for your face, fingerprint or passcode before it shows a transcript or lets you \
                    approve anything. Host connections are unaffected: the SSH key is protected separately.
                    """
                )
                .font(OpenPawTheme.Human.caption)
                .foregroundStyle(OpenPawTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Dictation

    private var dictation: some View {
        Panel(label: "Dictation") {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
                    Text("Language").microLabel()
                    // `.menu` explicitly: the automatic style collapses to a bare chevron here, leaving no way to
                    // see which language speech is being recognised as. `.labelsHidden()` drops the picker's own
                    // "Language" title, which the row above already states, while the menu keeps showing the
                    // selected value.
                    Picker("Language", selection: bind(\.dictationLocaleID)) {
                        ForEach(localeChoices, id: \.self) { identifier in
                            Text(localeName(identifier)).tag(identifier)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .font(OpenPawTheme.Machine.body)
                    .frame(minHeight: 44)
                    .accessibilityLabel("Dictation language")
                    .accessibilityValue(localeName(settings.dictationLocaleID))
                    Text(VoicePrivacyDisclosure.appleSpeech)
                        .font(OpenPawTheme.Human.caption)
                        .foregroundStyle(OpenPawTheme.textTertiary)
                }

                VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
                    Text("Default destination").microLabel()
                    Picker("Default destination", selection: bind(\.dictationMode)) {
                        ForEach(DictationMode.allCases, id: \.self) { mode in
                            Text(modeName(mode)).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(dictationExplanation)
                        .font(OpenPawTheme.Human.caption)
                        .foregroundStyle(OpenPawTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if model.dictation?.isAvailable != true {
                    Text("No dictation engine is available on this device, so these settings are inert for now.")
                        .font(OpenPawTheme.Human.caption)
                        .foregroundStyle(OpenPawTheme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var dictationExplanation: String {
        settings.dictationMode == .terminal
            ? "New composers can start on terminal draft where a screen supports it. The visible composer toggle is authoritative, and Execute is always explicit."
            : "New composers can start on agent draft where a screen supports it. The visible composer toggle is authoritative, and Send is always explicit."
    }

    private var localeChoices: [String] {
        var choices = Self.settingsLocaleChoices(deviceLocale: settings.dictationLocaleID)
        for identifier in Locale.preferredLanguages.map(VoiceLocaleChoices.normalize) where !choices.contains(identifier) {
            choices.append(identifier)
        }
        return choices
    }

    static func settingsLocaleChoices(deviceLocale: String) -> [String] {
        OpenPawSettings.dictationLocaleChoices(deviceLocale: deviceLocale)
    }

    private func localeName(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    private func modeName(_ mode: DictationMode) -> String {
        switch mode {
        case .terminal: "Terminal"
        case .composer: "Draft"
        }
    }

    // MARK: Terminal

    private var terminal: some View {
        Panel(label: "Terminal") {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
                    Text("Cell size").microLabel()
                    Stepper(value: bind(\.terminalFontSize), in: OpenPawSettings.fontSizeRange, step: 1) {
                        Text("\(Int(settings.terminalFontSize)) pt")
                            .font(OpenPawTheme.Machine.body)
                            .foregroundStyle(OpenPawTheme.textPrimary)
                    }
                    .frame(minHeight: 44)
                }

                VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
                    Text("Ground").microLabel()
                    Picker("Ground", selection: bind(\.terminalTheme)) {
                        ForEach(TerminalTheme.allCases, id: \.self) { theme in
                            Text(theme.displayName).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(verbatim: "$ cargo build --workspace")
                        .font(.system(size: settings.terminalFontSize, design: .monospaced))
                        .foregroundStyle(settings.terminalTheme.foreground)
                        .padding(OpenPawTheme.Space.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(settings.terminalTheme.background)
                        .overlay(Rectangle().stroke(OpenPawTheme.line, lineWidth: OpenPawTheme.hairline))
                        .accessibilityLabel("Sample of the \(settings.terminalTheme.displayName) ground")
                }

                Toggle(isOn: bind(\.applicationCursorKeys)) {
                    Text("Application cursor keys")
                        .font(OpenPawTheme.Machine.body)
                        .foregroundStyle(OpenPawTheme.textPrimary)
                }
                .frame(minHeight: 44)
                Text("Turn on when a full-screen program needs ESC O A arrows. Leave off for a plain shell.")
                    .font(OpenPawTheme.Human.caption)
                    .foregroundStyle(OpenPawTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Budgets

    private var budgets: some View {
        Panel(label: "Budgets") {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
                    Text("Scrollback").microLabel()
                    Picker("Scrollback", selection: bind(\.scrollbackLines)) {
                        ForEach(OpenPawSettings.scrollbackChoices, id: \.self) { lines in
                            Text("\(lines)").tag(lines)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text("Lines kept per session. Older lines are dropped once the budget is full.")
                        .font(OpenPawTheme.Human.caption)
                        .foregroundStyle(OpenPawTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
                    Text("Events per session").microLabel()
                    Picker("Events per session", selection: eventBudgetBinding) {
                        ForEach(OpenPawSettings.eventBudgetChoices, id: \.self) { budget in
                            Text("\(budget)").tag(budget)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(
                        """
                        Transcript events held in memory. A long agent run keeps only the most recent, which is \
                        what the event log pages through.
                        """
                    )
                    .font(OpenPawTheme.Human.caption)
                    .foregroundStyle(OpenPawTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var eventBudgetBinding: Binding<Int> {
        Binding(get: { model.eventBudgetPerSession }, set: { model.eventBudgetPerSession = $0 })
    }

    // MARK: Hosts

    private var hostSection: some View {
        Panel(label: "Hosts") {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                Text("OpenPaw dials nothing that is not on this list.")
                    .font(OpenPawTheme.Human.prose)
                    .foregroundStyle(OpenPawTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.hostStore.hosts.isEmpty {
                    Text("The list is empty.")
                        .font(OpenPawTheme.Machine.code)
                        .foregroundStyle(OpenPawTheme.textTertiary)
                } else {
                    VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
                        ForEach(model.hostStore.hosts) { host in
                            Text(verbatim: "\(host.username)@\(host.hostname):\(host.port)")
                                .font(OpenPawTheme.Machine.code)
                                .foregroundStyle(OpenPawTheme.textSecondary)
                                .textSelection(.enabled)
                        }
                    }
                }

                NavigationLink {
                    HostListView(model: model, settings: settings)
                } label: {
                    settingsLinkLabel("Manage hosts")
                }
                .buttonStyle(.plain)

                NavigationLink {
                    DiagnosticsView(model: model)
                } label: {
                    settingsLinkLabel("Diagnostics")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func settingsLinkLabel(_ title: String) -> some View {
        HStack(spacing: OpenPawTheme.Space.tight) {
            Text(title).font(OpenPawTheme.Machine.headline)
            Image(systemName: "chevron.right").font(OpenPawTheme.Machine.codeSmall)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .foregroundStyle(OpenPawTheme.textPrimary)
        .contentShape(Rectangle())
    }

    // MARK: Pairing

    private var pairing: some View {
        Panel(label: "Paired devices") {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                if let health = model.health {
                    MonoField(label: "This device holds", value: capabilitySummary(health), isCopyable: true)
                }

                if devices.isEmpty {
                    Text(
                        """
                        The audit log names no devices yet. Every decision made from a phone appears here with the \
                        device that made it.
                        """
                    )
                    .font(OpenPawTheme.Human.caption)
                    .foregroundStyle(OpenPawTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(devices) { device in
                        deviceRow(device)
                    }
                }

                Text(
                    """
                    Revoking happens on the host, not here. Remove a device there and its token stops working \
                    immediately; the SSH key is separate and is revoked by taking it out of authorized_keys.
                    """
                )
                .font(OpenPawTheme.Human.prose)
                .foregroundStyle(OpenPawTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

                MonoField(label: "Pair another device", value: "openpaw-host pairing-code", isCopyable: true)
            }
        }
    }

    private func capabilitySummary(_ health: HealthInfo) -> String {
        health.capabilities.isEmpty ? "no capabilities" : health.capabilities.joined(separator: " ")
    }

    private func deviceRow(_ device: PairedDevice) -> some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.hair) {
            Text(device.id)
                .font(OpenPawTheme.Machine.code)
                .foregroundStyle(OpenPawTheme.textPrimary)
                .textSelection(.enabled)
            HStack(spacing: OpenPawTheme.Space.large) {
                HStack(spacing: OpenPawTheme.Space.tight) {
                    Text("last seen").microLabel()
                    RelativeTime(date: device.lastSeen)
                        .font(OpenPawTheme.Machine.codeSmall)
                        .foregroundStyle(OpenPawTheme.textSecondary)
                }
                HStack(spacing: OpenPawTheme.Space.tight) {
                    Text("actions").microLabel()
                    Text("\(device.actions)")
                        .font(OpenPawTheme.Machine.codeSmall)
                        .foregroundStyle(OpenPawTheme.textSecondary)
                }
            }
        }
        .padding(.vertical, OpenPawTheme.Space.tight)
        .accessibilityElement(children: .combine)
    }

    private func loadDevices() async {
        guard let backend = model.backend else { return }
        do {
            devices = PairedDevice.derive(from: try await backend.audit(limit: 500))
        } catch {
            model.present(error, while: "reading the audit log")
        }
    }

    // MARK: Configuration transfer

    private var configuration: some View {
        Panel(label: "Configuration") {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                Text(
                    """
                    Carries the preferences on this screen, your terminal shortcuts and the per-host session \
                    profiles. Hosts themselves export separately from the host list.
                    """
                )
                .font(OpenPawTheme.Human.prose)
                .foregroundStyle(OpenPawTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: OpenPawTheme.Space.small) {
                    Button("Export JSON", action: startExport)
                        .buttonStyle(.plain)
                        .frame(minHeight: 44)
                        .foregroundStyle(OpenPawTheme.textPrimary)
                    Spacer(minLength: OpenPawTheme.Space.large)
                    Button("Import JSON") { isImporting = true }
                        .buttonStyle(.plain)
                        .frame(minHeight: 44)
                        .foregroundStyle(OpenPawTheme.textPrimary)
                }

                if let transferError {
                    ShellIssueText(transferError)
                }
            }
        }
    }

    private func startExport() {
        transferError = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let snapshot = settings.snapshot(eventBudget: model.eventBudgetPerSession)
            exportDocument = ShellJSONDocument(data: try encoder.encode(snapshot))
            isExporting = true
        } catch {
            transferError = "The settings could not be written: \(error)"
        }
    }

    private func importSettings(from result: Result<URL, any Error>) {
        transferError = nil
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let snapshot = try JSONDecoder().decode(SettingsSnapshot.self, from: data)
            model.eventBudgetPerSession = settings.apply(snapshot)
        } catch {
            transferError = "That file is not an OpenPaw settings export: \(error)"
        }
    }

    // MARK: About

    private var about: some View {
        HumanPanel {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                Text("About").microLabel()
                Text("OpenPaw")
                    .font(OpenPawTheme.Human.display)
                    .foregroundStyle(OpenPawTheme.textPrimary)
                Text(
                    """
                    OpenPaw is an independent open-source project. It is not affiliated with, endorsed by, or \
                    derived from any commercial mobile agent client. All trademarks belong to their respective \
                    owners. Nothing here was obtained by decompiling, reverse-engineering a paid product, or \
                    accessing a private API: the agent formats it reads are the ones those agents write into your \
                    own home directory, and you can read them yourself with cat.
                    """
                )
                .font(OpenPawTheme.Human.prose)
                .foregroundStyle(OpenPawTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

                Text(
                    """
                    Apache-2.0 for the code, CC BY 4.0 for the documentation. The OpenPaw name and logo are not \
                    covered by those grants, so nobody can pass off a modified build as an official one.
                    """
                )
                .font(OpenPawTheme.Human.caption)
                .foregroundStyle(OpenPawTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

                if let health = model.health {
                    MonoField(label: "Host", value: health.version, isCopyable: true)
                    MonoField(label: "Protocol", value: health.protocolVersion, isCopyable: true)
                }
            }
        }
    }

    // MARK: Binding helper

    /// Produces a `Binding` into an `@Observable` object the view does not own. Each property persists itself in
    /// `didSet`, so there is no separate save step to forget.
    private func bind<Value>(_ path: ReferenceWritableKeyPath<OpenPawSettings, Value>) -> Binding<Value> {
        Binding(get: { settings[keyPath: path] }, set: { settings[keyPath: path] = $0 })
    }
}

#Preview("Settings") {
    NavigationStack {
        SettingsView(model: PreviewBackend.model(.populated), settings: OpenPawSettings.preview())
    }
    .preferredColorScheme(.dark)
}

#Preview("Settings, disconnected") {
    NavigationStack {
        SettingsView(model: PreviewBackend.model(.disconnected), settings: OpenPawSettings.preview())
    }
    .preferredColorScheme(.dark)
}
