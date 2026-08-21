import Foundation

/// Destination for editable voice text. Pure UI state, not tied to a backend.
public enum VoiceDestination: String, Sendable, Hashable, Codable, CaseIterable {
    case agent
    case terminal

    public var dictationMode: DictationMode {
        switch self {
        case .agent: .composer
        case .terminal: .terminal
        }
    }
}

/// Explicit user action produced only by committing editable voice text.
public enum VoiceCommitAction: Sendable, Hashable {
    case sendAgent(String)
    case executeTerminal(String)
}

public enum VoiceLifecycle: Sendable, Hashable {
    case stopped
    case active
}

/// Destination-neutral composition state for typed and dictated text.
///
/// Recognition updates only stage editable text. Sending to an agent or executing in a terminal is represented by
/// `commit()` so views cannot accidentally make final speech recognition an execution path.
public struct VoiceComposition: Sendable, Hashable {
    public private(set) var destination: VoiceDestination
    public var draft: String
    public private(set) var partialTranscript: String
    public private(set) var lifecycle: VoiceLifecycle

    private var draftAtStart: String
    private var acceptsLateFinal: Bool

    public init(destination: VoiceDestination, draft: String = "") {
        self.destination = destination
        self.draft = draft
        self.partialTranscript = ""
        self.lifecycle = .stopped
        self.draftAtStart = draft
        self.acceptsLateFinal = false
    }

    public var isActive: Bool { lifecycle == .active }

    public var displayText: String {
        guard !partialTranscript.isEmpty else { return draft }
        guard !draft.isEmpty else { return partialTranscript }
        return Self.join(draft: draft, phrase: partialTranscript)
    }

    public mutating func start() {
        lifecycle = .active
        draftAtStart = draft
        partialTranscript = ""
        acceptsLateFinal = false
    }

    public mutating func stop() {
        guard lifecycle == .active else { return }
        lifecycle = .stopped
        acceptsLateFinal = true
    }

    public mutating func cancel() {
        draft = draftAtStart
        partialTranscript = ""
        lifecycle = .stopped
        acceptsLateFinal = false
    }

    @discardableResult
    public mutating func apply(_ update: DictationUpdate) -> VoiceCommitAction? {
        guard lifecycle == .active || (acceptsLateFinal && update.isFinal) else { return nil }
        if update.isFinal {
            draft = Self.join(draft: draftAtStart, phrase: update.text)
            partialTranscript = ""
            acceptsLateFinal = false
        } else if lifecycle == .active {
            partialTranscript = update.text
        }
        return nil
    }

    public mutating func switchDestination(to destination: VoiceDestination) {
        self.destination = destination
    }

    public mutating func commit() -> VoiceCommitAction? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        draft = ""
        partialTranscript = ""
        draftAtStart = ""
        acceptsLateFinal = false
        lifecycle = .stopped
        switch destination {
        case .agent:
            return .sendAgent(text)
        case .terminal:
            return .executeTerminal(text)
        }
    }

    static func join(draft: String, phrase: String) -> String {
        let phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return draft }
        guard !draft.isEmpty else { return phrase }
        return draft.hasSuffix(" ") || draft.hasSuffix("\n") ? draft + phrase : draft + " " + phrase
    }
}

/// Shared dictation locale choices for composer controls and settings screens.
public enum VoiceLocaleChoices {
    public static let firstClassLocales = ["en-US", "zh-CN"]

    public static func normalize(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-")
    }

    public static func choices(deviceLocale: String, firstClass: [String] = firstClassLocales) -> [String] {
        let device = normalize(deviceLocale)
        var identifiers = firstClass
        if !identifiers.contains(device) { identifiers.insert(device, at: 0) }
        return identifiers
    }
}
