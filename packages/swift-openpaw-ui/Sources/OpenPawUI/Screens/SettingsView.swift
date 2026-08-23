import Foundation
import OpenPawProtocol
import OpenPawTerminalCore
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var pendingImportProposal: SettingsImportProposal?
    @State private var selectedDestination: SettingsDestination?
    @State private var searchText = ""
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(
        model: OpenPawModel,
        settings: OpenPawSettings,
        initialDestination: SettingsDestination = SettingsSelectionPolicy.defaultDestination
    ) {
        self.model = model
        self.settings = settings
        _selectedDestination = State(initialValue: initialDestination)
    }

    public var body: some View {
        Group {
            switch SettingsPresentationPolicy.presentation(horizontalSizeClass: horizontalSizeClass) {
            case .stack:
                NavigationStack {
                    SettingsHomeView(searchText: searchText)
                        .navigationDestination(for: SettingsDestination.self) { destination in
                            categoryView(destination)
                        }
                        .searchable(text: $searchText, prompt: "Search settings")
                }
            case .split:
                HStack(spacing: 0) {
                    SettingsHomeView(
                        searchText: searchText,
                        selectedDestination: selectedDestination,
                        onSelect: { selectedDestination = SettingsSelectionPolicy.selection(afterSelecting: $0) }
                    )
                    .searchable(text: $searchText, prompt: "Search settings")
                    .frame(width: 340)
                    .background(OpenPawTheme.ink)

                    Rectangle()
                        .fill(OpenPawTheme.line)
                        .frame(width: OpenPawTheme.hairline)

                    categoryView(selectedDestination ?? SettingsSelectionPolicy.defaultDestination)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(OpenPawTheme.ink)
            }
        }
        .background(OpenPawTheme.ink)
        .tint(OpenPawTheme.textPrimary)
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

    @ViewBuilder
    private func categoryView(_ destination: SettingsDestination) -> some View {
        let category = destination.category
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: OpenPawTheme.Space.large) {
                    switch category {
                    case .appearance:
                        appearance
                    case .terminal:
                        terminal
                    case .voice:
                        dictation
                    case .connection:
                        hostSection
                        connection
                    case .sessions:
                        budgets
                    case .agents:
                        agents
                    case .repositories:
                        repositories
                    case .security:
                        security
                        pairing
                    case .data:
                        configuration
                    case .diagnostics:
                        diagnostics
                    case .about:
                        about
                    }
                }
                .padding(OpenPawTheme.Space.large)
                .frame(maxWidth: 720, alignment: .leading)
            }
            .background(OpenPawTheme.ink)
            .navigationTitle(category.title)
            .accessibilityIdentifier("settings.detail.\(category.id)")
            .onAppear {
                if let controlID = destination.controlID {
                    proxy.scrollTo(controlID, anchor: .center)
                }
            }
            .onChange(of: destination) { _, newDestination in
                if let controlID = newDestination.controlID {
                    proxy.scrollTo(controlID, anchor: .center)
                }
            }
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
                .id(SettingsControl.biometricGate.id)
                .accessibilityIdentifier(SettingsControl.biometricGate.accessibilityIdentifier)
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
                    .id(SettingsControl.dictationLanguage.id)
                    .accessibilityIdentifier(SettingsControl.dictationLanguage.accessibilityIdentifier)
                    Text(privacyDisclosure)
                        .font(OpenPawTheme.Human.caption)
                        .foregroundStyle(OpenPawTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                engineChoice

                VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
                    Text("Default destination").microLabel()
                    Picker("Default destination", selection: bind(\.dictationMode)) {
                        ForEach(DictationMode.allCases, id: \.self) { mode in
                            Text(modeName(mode)).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .id(SettingsControl.dictationDestination.id)
                    .accessibilityIdentifier(SettingsControl.dictationDestination.accessibilityIdentifier)
                    Text(dictationExplanation)
                        .font(OpenPawTheme.Human.caption)
                        .foregroundStyle(OpenPawTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Only when nothing can be done about it. A local engine whose weights are still absent also has no
                // live recogniser, but the row above already says "Not downloaded" next to the button that fixes
                // it, and telling that user their device cannot dictate would be both false and discouraging.
                if model.dictation?.isAvailable != true, !engineAwaitsDownload {
                    Text("No dictation engine is available on this device, so these settings are inert for now.")
                        .font(OpenPawTheme.Human.caption)
                        .foregroundStyle(OpenPawTheme.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Which recogniser runs, and whether its weights are on the phone yet.
    ///
    /// The download button lives next to the picker rather than behind a separate "manage models" screen because
    /// selecting an engine whose weights are absent is the same act as wanting them: hiding the fetch one
    /// navigation level away produces a setting that is switched on and does nothing.
    @ViewBuilder
    private var engineChoice: some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
            Text("Recogniser").microLabel()
            Picker("Recogniser", selection: engineSelection) {
                ForEach(engineChoices, id: \.self) { choice in
                    Text(choice.displayName).tag(choice)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .font(OpenPawTheme.Machine.body)
            .frame(minHeight: 44)
            .accessibilityLabel("Dictation recogniser")
            .accessibilityValue(settings.effectiveDictationEngine.displayName)
            .id(SettingsControl.dictationRecogniser.id)
            .accessibilityIdentifier(SettingsControl.dictationRecogniser.accessibilityIdentifier)

            Text(settings.effectiveDictationEngine.summary)
                .font(OpenPawTheme.Human.caption)
                .foregroundStyle(OpenPawTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            // Said only when the stored choice was overruled, and it names both engines: "why is this on Apple when
            // I picked Qwen" is otherwise unanswerable from this screen.
            if settings.dictationEngine != settings.effectiveDictationEngine {
                Text(
                    "\(settings.dictationEngine.displayName) cannot transcribe "
                        + "\(localeName(settings.dictationLocaleID)), so "
                        + "\(settings.effectiveDictationEngine.displayName) is being used for it."
                )
                .font(OpenPawTheme.Human.caption)
                .foregroundStyle(OpenPawTheme.warn)
                .fixedSize(horizontal: false, vertical: true)
            }

            if settings.effectiveDictationEngine.requiresDownload {
                modelRow(for: settings.effectiveDictationEngine)
            }
        }
    }

    /// The download state of one engine, and the single action available in that state.
    @ViewBuilder
    private func modelRow(for choice: DictationEngineChoice) -> some View {
        let state = model.dictationModels.state(of: choice)
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
            if case .downloading(let progress, _) = state {
                ProgressView(value: progress)
                    .tint(OpenPawTheme.textPrimary)
                    .accessibilityLabel("Downloading \(choice.displayName)")
                    .accessibilityValue("\(Int(progress * 100)) percent")
            }
            HStack(spacing: OpenPawTheme.Space.tight) {
                if let status = state.statusText {
                    Text(status)
                        .font(OpenPawTheme.Human.caption)
                        .foregroundStyle(statusColor(state))
                }
                Spacer(minLength: 0)
                switch state {
                case .absent, .failed:
                    Button("Download \(choice.approximateDownloadMegabytes) MB") {
                        model.dictationModels.install(choice)
                    }
                    .buttonStyle(.bordered)
                    .font(OpenPawTheme.Machine.code)
                case .downloading:
                    Button("Cancel") { model.dictationModels.cancelInstall(of: choice) }
                        .buttonStyle(.bordered)
                        .font(OpenPawTheme.Machine.code)
                case .installed:
                    Button("Remove") { model.dictationModels.remove(choice) }
                        .buttonStyle(.bordered)
                        .font(OpenPawTheme.Machine.code)
                case .unsupported:
                    // No button. The state says why, and every action this row could offer would fail the same way.
                    EmptyView()
                }
            }
            .frame(minHeight: 44)
        }
    }

    private func statusColor(_ state: DictationModelState) -> Color {
        switch state {
        case .failed, .unsupported: OpenPawTheme.warn
        case .installed: OpenPawTheme.textTertiary
        default: OpenPawTheme.textTertiary
        }
    }

    private var engineChoices: [DictationEngineChoice] {
        DictationEngineChoice.choices(forLocale: settings.dictationLocaleID)
    }

    /// Reads the engine that will actually run and writes the one the user picked.
    ///
    /// Asymmetric on purpose. A `Picker` whose selection is not among its tags draws an empty box, and the stored
    /// choice is exactly that whenever the language rules it out — a user who once chose Parakeet and then switched
    /// to Chinese was shown a recogniser field with nothing in it. Reading the resolved engine keeps the field
    /// truthful about what will happen, while writing the raw choice keeps the preference the user expressed, so
    /// switching the language back restores it.
    private var engineSelection: Binding<DictationEngineChoice> {
        Binding(
            get: { settings.effectiveDictationEngine },
            set: { settings.dictationEngine = $0 }
        )
    }

    /// True when the row above already explains why this engine is not running.
    ///
    /// Two cases, both of which the row states plainly: the weights have not been fetched yet, or this device
    /// cannot run them at all. Adding "no dictation engine is available on this device" underneath either one is a
    /// second, vaguer sentence about the same fact, and in the download case it is also wrong.
    private var engineAwaitsDownload: Bool {
        let choice = settings.effectiveDictationEngine
        guard choice.requiresDownload else { return false }
        return !model.dictationModels.state(of: choice).isInstalled
    }

    /// Where the user's voice goes, stated per engine rather than once for the screen.
    ///
    /// Apple's recogniser may leave the device for some locales, and the local models never can. Printing Apple's
    /// caveat under a downloaded model would be a false statement about the user's privacy, in the direction that
    /// makes the product look worse than it is, so the sentence follows the choice.
    private var privacyDisclosure: String {
        settings.effectiveDictationEngine == .appleSpeech
            ? VoicePrivacyDisclosure.appleSpeech
            : VoicePrivacyDisclosure.localModel
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

    private var appearance: some View {
        Panel(label: "Appearance") {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                Text("App chrome status").microLabel()
                Text("OpenPaw currently ships one dark app chrome.")
                    .font(OpenPawTheme.Machine.body)
                    .foregroundStyle(OpenPawTheme.textPrimary)
                Text("Light and high-contrast app chrome are not available yet. Terminal ground is configured in Terminal settings.")
                    .font(OpenPawTheme.Human.caption)
                    .foregroundStyle(OpenPawTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
                    unavailableAppearanceMode("Light app chrome")
                    unavailableAppearanceMode("High-contrast app chrome")
                }
            }
        }
    }

    private func unavailableAppearanceMode(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(OpenPawTheme.Machine.body)
                .foregroundStyle(OpenPawTheme.textSecondary)
            Spacer()
            Text("Unavailable")
                .font(OpenPawTheme.Human.caption)
                .foregroundStyle(OpenPawTheme.textTertiary)
        }
        .frame(minHeight: 44)
        .padding(.horizontal, OpenPawTheme.Space.small)
        .background(OpenPawTheme.well.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.machine, style: .continuous))
    }

    private var terminal: some View {
        Panel(label: "Terminal") {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
                    Text("Terminal ground").microLabel()
                    Picker("Terminal ground", selection: bind(\.terminalTheme)) {
                        ForEach(TerminalTheme.allCases, id: \.self) { theme in
                            Text(theme.displayName).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .id(SettingsControl.terminalGround.id)
                    .accessibilityIdentifier(SettingsControl.terminalGround.accessibilityIdentifier)
                    Text("Controls only the terminal surface and sample preview. App chrome stays on OpenPaw's dark palette.")
                        .font(OpenPawTheme.Human.caption)
                        .foregroundStyle(OpenPawTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
                    Text("Cell size").microLabel()
                    Stepper(value: bind(\.terminalFontSize), in: OpenPawSettings.fontSizeRange, step: 1) {
                        Text("\(Int(settings.terminalFontSize)) pt")
                            .font(OpenPawTheme.Machine.body)
                            .foregroundStyle(OpenPawTheme.textPrimary)
                    }
                    .frame(minHeight: 44)
                    .id(SettingsControl.terminalCellSize.id)
                    .accessibilityIdentifier(SettingsControl.terminalCellSize.accessibilityIdentifier)
                }

                Text(verbatim: "$ cargo build --workspace")
                    .font(.system(size: settings.terminalFontSize, design: .monospaced))
                    .foregroundStyle(settings.terminalTheme.foreground)
                    .padding(OpenPawTheme.Space.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(settings.terminalTheme.background)
                    .clipShape(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.machine, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.machine, style: .continuous).stroke(OpenPawTheme.line, lineWidth: OpenPawTheme.hairline))
                    .accessibilityLabel("Sample of the \(settings.terminalTheme.displayName) ground")

                Toggle(isOn: bind(\.applicationCursorKeys)) {
                    Text("Application cursor keys")
                        .font(OpenPawTheme.Machine.body)
                        .foregroundStyle(OpenPawTheme.textPrimary)
                }
                .frame(minHeight: 44)
                .id(SettingsControl.cursorKeys.id)
                .accessibilityIdentifier(SettingsControl.cursorKeys.accessibilityIdentifier)
                Text("Turn on when a full-screen program needs ESC O A arrows. Leave off for a plain shell.")
                    .font(OpenPawTheme.Human.caption)
                    .foregroundStyle(OpenPawTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle(isOn: bind(\.isShortcutBarVisible)) {
                    Text("Shortcut bar")
                        .font(OpenPawTheme.Machine.body)
                        .foregroundStyle(OpenPawTheme.textPrimary)
                }
                .frame(minHeight: 44)
                .id(SettingsControl.shortcutBar.id)
                .accessibilityIdentifier(SettingsControl.shortcutBar.accessibilityIdentifier)
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
                    .id(SettingsControl.scrollback.id)
                    .accessibilityIdentifier(SettingsControl.scrollback.accessibilityIdentifier)
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
                    .id(SettingsControl.eventBudget.id)
                    .accessibilityIdentifier(SettingsControl.eventBudget.accessibilityIdentifier)
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
        Binding(get: { settings.eventBudgetPerSession }, set: { settings.eventBudgetPerSession = $0 })
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
                .id(SettingsControl.manageHosts.id)
                .accessibilityIdentifier(SettingsControl.manageHosts.accessibilityIdentifier)

                NavigationLink {
                    DiagnosticsView(model: model)
                } label: {
                    settingsLinkLabel("Diagnostics")
                }
                .buttonStyle(.plain)
                .id(SettingsControl.diagnostics.id)
                .accessibilityIdentifier(SettingsControl.diagnostics.accessibilityIdentifier)
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
                        .id(SettingsControl.exportJSON.id)
                        .accessibilityIdentifier(SettingsControl.exportJSON.accessibilityIdentifier)
                    Spacer(minLength: OpenPawTheme.Space.large)
                    Button("Import JSON") { isImporting = true }
                        .buttonStyle(.plain)
                        .frame(minHeight: 44)
                        .foregroundStyle(OpenPawTheme.textPrimary)
                        .id(SettingsControl.importJSON.id)
                        .accessibilityIdentifier(SettingsControl.importJSON.accessibilityIdentifier)
                }

                VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
                    Text("Reset categories")
                        .microLabel()
                    Text("Resets only settings owned by this screen. Hosts, host credentials and Keychain material are never deleted here.")
                        .font(OpenPawTheme.Human.caption)
                        .foregroundStyle(OpenPawTheme.textSecondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: OpenPawTheme.Space.small)], alignment: .leading, spacing: OpenPawTheme.Space.small) {
                        resetButton("Appearance", .appearanceAndTerminal)
                        resetButton("Voice", .voice)
                        resetButton("Connections", .connections)
                        resetButton("Sessions", .sessionsAndBudgets)
                        resetButton("Security", .security)
                        resetButton("All settings", .dataAll)
                    }
                }

                if let transferError {
                    ShellIssueText(transferError)
                }

                if let pendingImportProposal {
                    importProposalSummary(pendingImportProposal)
                }
            }
        }
    }

    private func importProposalSummary(_ proposal: SettingsImportProposal) -> some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
            Text("Pending import")
                .font(OpenPawTheme.Human.proseTight)
                .foregroundStyle(OpenPawTheme.textPrimary)
            Text(importSummaryText(proposal))
                .font(OpenPawTheme.Machine.codeSmall)
                .foregroundStyle(OpenPawTheme.textSecondary)
                .textSelection(.enabled)
            HStack(spacing: OpenPawTheme.Space.small) {
                Button("Cancel import", role: .cancel, action: cancelImportProposal)
                    .buttonStyle(.plain)
                Button(proposal.securityReductions.isEmpty ? "Apply import" : "Apply security-reducing import") {
                    applyPendingImport(confirmSecurityReductions: !proposal.securityReductions.isEmpty)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(OpenPawTheme.Space.medium)
        .background(OpenPawTheme.panel.opacity(0.9), in: RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card))
        .accessibilityIdentifier("settings.import.proposal")
    }

    private func resetButton(_ title: String, _ category: SettingsResetCategory) -> some View {
        Button(title) { stageReset(category) }
            .buttonStyle(.plain)
            .frame(minHeight: 44, alignment: .leading)
            .accessibilityIdentifier("settings.reset.\(category.rawValue)")
    }

    private func startExport() {
        transferError = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let snapshot = settings.snapshot()
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
            let proposal = try SettingsImportProposal.parse(data, current: settings)
            pendingImportProposal = proposal
        } catch {
            transferError = "That file is not an OpenPaw settings export: \(error)"
        }
    }

    private func stageReset(_ category: SettingsResetCategory) {
        transferError = nil
        do {
            pendingImportProposal = try SettingsImportProposal.reset(category, current: settings)
        } catch {
            transferError = "That reset could not be prepared: \(error)"
        }
    }

    private func applyPendingImport(confirmSecurityReductions: Bool) {
        guard let proposal = pendingImportProposal else { return }
        transferError = nil
        do {
            try settings.apply(proposal, confirmSecurityReductions: confirmSecurityReductions)
            pendingImportProposal = nil
        } catch {
            transferError = "That import could not be applied: \(error)"
        }
    }

    private func cancelImportProposal() {
        pendingImportProposal = nil
    }

    private func importSummaryText(_ proposal: SettingsImportProposal) -> String {
        var lines = proposal.changes.map { change in
            "\(change.category.rawValue).\(change.controlID): \(change.oldDisplayValue) → \(change.newDisplayValue)"
        }
        if !proposal.securityReductions.isEmpty {
            lines.insert("Security reduction requires explicit confirmation: \(proposal.securityReductions.map(\.rawValue).sorted().joined(separator: ", "))", at: 0)
        }
        return lines.isEmpty ? "No settings changes detected." : lines.joined(separator: "\n")
    }

    private var connection: some View {
        Panel(label: "Transport") {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                Text("OpenPaw uses the hosts you configure here. SSH identity, Tailscale reachability, Mosh, and Eternal Terminal support are host capabilities, not phone-side secrets.")
                    .font(OpenPawTheme.Human.prose)
                    .foregroundStyle(OpenPawTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
                    Text("Preview port").microLabel()
                    Stepper(value: bind(\.previewPort), in: 1...65_535, step: 1) {
                        Text("\(settings.previewPort)")
                            .font(OpenPawTheme.Machine.body)
                            .foregroundStyle(OpenPawTheme.textPrimary)
                    }
                    .frame(minHeight: 44)
                    .id(SettingsControl.previewPort.id)
                    .accessibilityIdentifier(SettingsControl.previewPort.accessibilityIdentifier)
                }
            }
        }
    }

    private var sessionOwnership: some View {
        Panel(label: "Host-specific session profiles") {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                Text("Terminal geometry and per-host session behavior stay with each host record. Manage them from Hosts so Settings does not become a second owner of the same profile data.")
                    .font(OpenPawTheme.Human.prose)
                    .foregroundStyle(OpenPawTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                NavigationLink { HostListView(model: model, settings: settings) } label: { settingsLinkLabel("Open hosts") }
                    .buttonStyle(.plain)
            }
        }
    }

    private var agents: some View {
        Panel(label: "Agents") {
            Text("Agent approvals remain explicit in each workspace. Settings records device defaults only, so execution ownership stays with the active session.")
                .font(OpenPawTheme.Human.prose)
                .foregroundStyle(OpenPawTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var repositories: some View {
        Panel(label: "Repositories & providers") {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                Text("Repository roots and provider tokens belong to the host. OpenPaw shows status and starts host-mediated imports without storing GitHub or Hugging Face credentials on this device.")
                    .font(OpenPawTheme.Human.prose)
                    .foregroundStyle(OpenPawTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                NavigationLink { HostListView(model: model, settings: settings) } label: { settingsLinkLabel("Manage host repositories") }
                    .buttonStyle(.plain)
            }
        }
    }

    private var diagnostics: some View {
        Panel(label: "Diagnostics") {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                Text("Health, protocol, and audit details stay in the diagnostics screen so troubleshooting has one source of truth.")
                    .font(OpenPawTheme.Human.prose)
                    .foregroundStyle(OpenPawTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                NavigationLink { DiagnosticsView(model: model) } label: { settingsLinkLabel("Open diagnostics") }
                    .buttonStyle(.plain)
            }
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
