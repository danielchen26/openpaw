import SwiftUI

public enum SettingsCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
    case appearance
    case terminal
    case voice
    case connection
    case sessions
    case agents
    case repositories
    case security
    case data
    case diagnostics
    case about

    public var id: String { rawValue }
    public var accessibilityIdentifier: String { "settings.category.\(id)" }

    public var title: String {
        switch self {
        case .appearance: "Appearance"
        case .terminal: "Terminal"
        case .voice: "Voice & Dictation"
        case .connection: "Connections"
        case .sessions: "Sessions & Budgets"
        case .agents: "Agents"
        case .repositories: "Repositories & Providers"
        case .security: "Security"
        case .data: "Data"
        case .diagnostics: "Diagnostics"
        case .about: "About"
        }
    }

    public var summary: String {
        switch self {
        case .appearance: "Theme and app chrome preferences."
        case .terminal: "Cell size, ground, cursor keys, shortcuts, and scrollback."
        case .voice: "Dictation language, recogniser, model downloads, and destination."
        case .connection: "Preview ports, transport notes, and host links."
        case .sessions: "Session event budgets and host-specific profile links."
        case .agents: "Agent defaults and execution safety."
        case .repositories: "Repository browser, provider connections, and imports."
        case .security: "Face ID gate, paired devices, and revocation guidance."
        case .data: "Import, export, reset, and settings portability."
        case .diagnostics: "Health, audit, and troubleshooting entry points."
        case .about: "Version, protocol, license, and legal notices."
        }
    }

    public var keywords: [String] {
        switch self {
        case .appearance: ["appearance", "theme", "chrome", "light", "dark"]
        case .terminal: ["terminal", "cell", "font", "ground", "cursor", "shortcuts"]
        case .voice: ["voice", "dictation", "language", "recogniser", "recognizer", "speech", "qwen", "parakeet"]
        case .connection: ["connection", "host", "transport", "preview", "port", "tailscale", "mosh", "ssh"]
        case .sessions: ["session", "budget", "events", "profile", "scrollback"]
        case .agents: ["agent", "approval", "execute", "safety"]
        case .repositories: ["repository", "repositories", "repo", "provider", "github", "hugging face", "import"]
        case .security: ["security", "face id", "touch id", "biometric", "passcode", "paired", "device", "revoke"]
        case .data: ["data", "import", "export", "json", "reset", "backup"]
        case .diagnostics: ["diagnostics", "health", "audit", "logs", "troubleshooting"]
        case .about: ["about", "license", "legal", "protocol", "version", "trademark"]
        }
    }
}

public enum SettingsControl: String, CaseIterable, Identifiable, Hashable, Sendable {
    case biometricGate = "biometric-gate"
    case dictationLanguage = "dictation-language"
    case dictationRecogniser = "dictation-recogniser"
    case dictationDestination = "dictation-destination"
    case terminalCellSize = "terminal-cell-size"
    case terminalGround = "terminal-ground"
    case cursorKeys = "application-cursor-keys"
    case shortcutBar = "shortcut-bar"
    case scrollback = "scrollback"
    case eventBudget = "event-budget"
    case previewPort = "preview-port"
    case manageHosts = "manage-hosts"
    case diagnostics = "diagnostics"
    case exportJSON = "export-json"
    case importJSON = "import-json"

    public var id: String { rawValue }
    public var accessibilityIdentifier: String { "settings.control.\(id)" }
}

public struct SettingsDestination: Hashable, Sendable {
    public let category: SettingsCategory
    public let controlID: String?

    public init(category: SettingsCategory, controlID: String? = nil) {
        self.category = category
        self.controlID = controlID
    }

    public init?(categoryID: String, controlID: String?) {
        guard let category = SettingsCategory(rawValue: categoryID) else { return nil }
        self.init(category: category, controlID: controlID)
    }
}

public struct SettingsSearchResult: Identifiable, Hashable, Sendable {
    public var id: String { destination.category.id + ":" + (destination.controlID ?? "category") }
    public let title: String
    public let subtitle: String
    public let category: SettingsCategory
    public let destination: SettingsDestination
    public let keywords: [String]
}

public enum SettingsSearchIndex {
    public static let entries: [SettingsSearchResult] = [
        .init(title: "Theme", subtitle: "Appearance", category: .appearance, destination: .init(category: .appearance, controlID: SettingsControl.terminalGround.id), keywords: ["theme", "ground", "appearance", "chrome", "slate", "deep", "warm"]),
        .init(title: "Require Face ID", subtitle: "Security", category: .security, destination: .init(category: .security, controlID: SettingsControl.biometricGate.id), keywords: ["face id", "touch id", "biometric", "passcode", "lock"]),
        .init(title: "Dictation language", subtitle: "Voice & Dictation", category: .voice, destination: .init(category: .voice, controlID: SettingsControl.dictationLanguage.id), keywords: ["language", "locale", "voice", "speech"]),
        .init(title: "Recogniser", subtitle: "Voice & Dictation", category: .voice, destination: .init(category: .voice, controlID: SettingsControl.dictationRecogniser.id), keywords: ["recogniser", "recognizer", "engine", "model", "qwen", "parakeet"]),
        .init(title: "Default dictation destination", subtitle: "Voice & Dictation", category: .voice, destination: .init(category: .voice, controlID: SettingsControl.dictationDestination.id), keywords: ["destination", "draft", "composer", "terminal", "dictation"]),
        .init(title: "Cell size", subtitle: "Terminal", category: .terminal, destination: .init(category: .terminal, controlID: SettingsControl.terminalCellSize.id), keywords: ["font", "cell", "terminal", "size"]),
        .init(title: "Application cursor keys", subtitle: "Terminal", category: .terminal, destination: .init(category: .terminal, controlID: SettingsControl.cursorKeys.id), keywords: ["cursor", "arrow", "esc", "application", "terminal"]),
        .init(title: "Shortcut bar", subtitle: "Terminal", category: .terminal, destination: .init(category: .terminal, controlID: SettingsControl.shortcutBar.id), keywords: ["shortcut", "bar", "escape", "touch", "keyboard", "terminal"]),
        .init(title: "Scrollback", subtitle: "Terminal", category: .terminal, destination: .init(category: .terminal, controlID: SettingsControl.scrollback.id), keywords: ["scrollback", "lines", "history", "terminal"]),
        .init(title: "Preview port", subtitle: "Connections", category: .connection, destination: .init(category: .connection, controlID: SettingsControl.previewPort.id), keywords: ["preview", "port", "connection", "forward"]),
        .init(title: "Manage hosts", subtitle: "Connections", category: .connection, destination: .init(category: .connection, controlID: SettingsControl.manageHosts.id), keywords: ["host", "hosts", "ssh", "manage", "connection"]),
        .init(title: "Diagnostics", subtitle: "Connections", category: .connection, destination: .init(category: .connection, controlID: SettingsControl.diagnostics.id), keywords: ["diagnostics", "health", "audit", "logs", "troubleshooting"]),
        .init(title: "Event budget", subtitle: "Sessions & Budgets", category: .sessions, destination: .init(category: .sessions, controlID: SettingsControl.eventBudget.id), keywords: ["event", "budget", "session", "memory"]),
        .init(title: "Provider connections", subtitle: "Repositories & Providers", category: .repositories, destination: .init(category: .repositories), keywords: ["github", "hugging face", "provider", "repository", "repo", "import"]),
        .init(title: "Export JSON", subtitle: "Data", category: .data, destination: .init(category: .data, controlID: SettingsControl.exportJSON.id), keywords: ["export", "json", "backup", "data"]),
        .init(title: "Import JSON", subtitle: "Data", category: .data, destination: .init(category: .data, controlID: SettingsControl.importJSON.id), keywords: ["import", "json", "restore", "data"]),
    ]

    public static func results(for query: String) -> [SettingsSearchResult] {
        let terms = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !terms.isEmpty else { return [] }
        return entries.filter { entry in
            let haystack = ([entry.title, entry.subtitle, entry.category.title, entry.category.summary] + entry.keywords + entry.category.keywords).joined(separator: " ").lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
    }
}

public enum SettingsPresentation: Hashable, Sendable { case stack, split }

public enum SettingsPresentationPolicy {
    public static func presentation(horizontalSizeClass: UserInterfaceSizeClass?) -> SettingsPresentation {
        horizontalSizeClass == .regular ? .split : .stack
    }
}

public enum SettingsSelectionPolicy {
    public static let defaultDestination = SettingsDestination(category: .security)

    public static func selection(afterSelecting destination: SettingsDestination) -> SettingsDestination {
        destination
    }
}

public struct SettingsHomeView: View {
    private let searchText: String
    private let selectedDestination: SettingsDestination?
    private let onSelect: ((SettingsDestination) -> Void)?

    public init(
        searchText: String = "",
        selectedDestination: SettingsDestination? = nil,
        onSelect: ((SettingsDestination) -> Void)? = nil
    ) {
        self.searchText = searchText
        self.selectedDestination = selectedDestination
        self.onSelect = onSelect
    }

    public var body: some View {
        List {
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ForEach(SettingsCategory.allCases) { category in
                    destinationRow(SettingsDestination(category: category)) { SettingsCategoryRow(category: category) }
                    .accessibilityIdentifier(category.accessibilityIdentifier)
                }
            } else {
                ForEach(SettingsSearchIndex.results(for: searchText)) { result in
                    destinationRow(result.destination) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.title)
                            Text(result.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("settings.search-result.\(result.id)")
                }
            }
        }
        .navigationTitle("Settings")
        .scrollContentBackground(.hidden)
        .background(OpenPawTheme.ink)
        .tint(OpenPawTheme.textPrimary)
        .accessibilityIdentifier("settings.home")
    }

    @ViewBuilder
    private func destinationRow<Label: View>(_ destination: SettingsDestination, @ViewBuilder label: () -> Label) -> some View {
        if let onSelect {
            Button { onSelect(destination) } label: { label().frame(maxWidth: .infinity, alignment: .leading) }
                .buttonStyle(.plain)
                .listRowBackground(selectionBackground(for: destination))
        } else {
            NavigationLink(value: destination) { label() }
        }
    }

    private func selectionBackground(for destination: SettingsDestination) -> Color {
        selectedDestination?.category == destination.category ? OpenPawTheme.panel.opacity(0.7) : .clear
    }
}

private struct SettingsCategoryRow: View {
    let category: SettingsCategory

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(category.title).font(OpenPawTheme.Machine.headline)
            Text(category.summary).font(OpenPawTheme.Human.caption).foregroundStyle(OpenPawTheme.textSecondary)
        }
        .frame(minHeight: 44, alignment: .leading)
    }
}
