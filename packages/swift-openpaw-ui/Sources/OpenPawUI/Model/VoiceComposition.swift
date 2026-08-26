import Foundation

/// Destination for editable voice text. Pure UI state, not tied to a backend.
public enum VoiceDestination: String, Sendable, Hashable, Codable, CaseIterable {
    case agent
    case terminal

    public init(dictationMode: DictationMode) {
        self = dictationMode == .terminal ? .terminal : .agent
    }

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

    public var terminalTextToSend: String? {
        guard case .executeTerminal(let text) = self else { return nil }
        return text.hasSuffix("\n") ? text : text + "\n"
    }
}

public struct VoiceTurnID: Sendable, Hashable {
    fileprivate let generation: Int
}

public enum VoiceLifecycle: Sendable, Hashable {
    case stopped
    case active
}

public enum VoicePrivacyDisclosure {
    public static let appleSpeech = "Speech may use Apple's on-device recognizer. If on-device recognition is unavailable for the selected language or device, Apple may use fallback recognition outside this app."
    /// A downloaded model runs inside this app's process. The only network access it involves is the one-time
    /// weight fetch, which is worth naming because that download is the thing the user consented to.
    public static let localModel = "Speech is transcribed by a model stored on this device, inside this app. Audio never leaves the phone, and the only network access is the one-time model download."
}

public struct DictationUnavailableError: LocalizedError, Sendable, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

public enum VoiceTerminalActionController {
    public static func execute(
        composition: inout VoiceComposition,
        send: (String) async throws -> Void
    ) async -> Bool {
        guard let action = composition.commit(), let text = action.terminalTextToSend else { return false }
        do {
            try await send(text)
            composition.clearAfterSuccessfulCommit()
            return true
        } catch {
            return false
        }
    }
}

public enum VoiceCommitError: LocalizedError, Sendable, Equatable {
    case terminalAttachments
    case agentAttachmentsNeedUpload

    public var errorDescription: String? {
        switch self {
        case .terminalAttachments:
            "Remove attachments before executing a terminal draft."
        case .agentAttachmentsNeedUpload:
            "Connect to a host before sending attachments."
        }
    }
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
    public private(set) var isEngineReady: Bool

    private var draftAtStart: String
    private var acceptsLateFinal: Bool
    private var provisionalPhrase: String?
    private var generation: Int
    private var activeTurn: VoiceTurnID?
    private var lateFinalTurn: VoiceTurnID?

    public init(destination: VoiceDestination, draft: String = "") {
        self.destination = destination
        self.draft = draft
        self.partialTranscript = ""
        self.lifecycle = .stopped
        self.isEngineReady = false
        self.draftAtStart = draft
        self.acceptsLateFinal = false
        self.provisionalPhrase = nil
        self.generation = 0
        self.activeTurn = nil
        self.lateFinalTurn = nil
    }

    public var isActive: Bool { lifecycle == .active }

    public var displayText: String {
        guard !partialTranscript.isEmpty else { return draft }
        guard !draft.isEmpty else { return partialTranscript }
        return Self.join(draft: draft, phrase: partialTranscript)
    }

    @discardableResult
    public mutating func start() -> VoiceTurnID {
        generation += 1
        let turn = VoiceTurnID(generation: generation)
        lifecycle = .active
        isEngineReady = false
        draftAtStart = draft
        partialTranscript = ""
        acceptsLateFinal = false
        provisionalPhrase = nil
        activeTurn = turn
        lateFinalTurn = nil
        return turn
    }

    public mutating func stop() {
        guard lifecycle == .active else { return }
        lifecycle = .stopped
        isEngineReady = false
        let provisional = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !provisional.isEmpty {
            draft = Self.join(draft: draftAtStart, phrase: provisional)
            provisionalPhrase = provisional
            partialTranscript = ""
        }
        acceptsLateFinal = true
        lateFinalTurn = activeTurn
        activeTurn = nil
    }

    public mutating func cancel() {
        draft = draftAtStart
        partialTranscript = ""
        lifecycle = .stopped
        isEngineReady = false
        acceptsLateFinal = false
        provisionalPhrase = nil
        activeTurn = nil
        lateFinalTurn = nil
    }

    @discardableResult
    public mutating func apply(_ update: DictationUpdate) -> VoiceCommitAction? {
        apply(update, turn: activeTurn ?? lateFinalTurn)
    }

    @discardableResult
    public mutating func apply(_ update: DictationUpdate, turn: VoiceTurnID?) -> VoiceCommitAction? {
        let ownsActiveTurn = lifecycle == .active && turn == activeTurn
        let ownsLateFinal = acceptsLateFinal && update.isFinal && turn == lateFinalTurn
        guard ownsActiveTurn || ownsLateFinal else { return nil }
        if ownsActiveTurn, update.isReady {
            isEngineReady = true
            if update.text.isEmpty, !update.isFinal { return nil }
        }
        if update.isFinal {
            let baseDraft: String
            if ownsLateFinal {
                if acceptsLateFinal, let provisionalPhrase {
                    let stagedProvisional = Self.join(draft: draftAtStart, phrase: provisionalPhrase)
                    guard draft == stagedProvisional else {
                        partialTranscript = ""
                        acceptsLateFinal = false
                        self.provisionalPhrase = nil
                        lateFinalTurn = nil
                        return nil
                    }
                    baseDraft = draftAtStart
                } else {
                    guard draft == draftAtStart else {
                        partialTranscript = ""
                        acceptsLateFinal = false
                        lateFinalTurn = nil
                        return nil
                    }
                    baseDraft = draftAtStart
                }
            } else {
                baseDraft = partialTranscript.isEmpty ? draft : draftAtStart
            }
            draft = Self.join(draft: baseDraft, phrase: update.text)
            partialTranscript = ""
            acceptsLateFinal = false
            provisionalPhrase = nil
            if ownsLateFinal { lateFinalTurn = nil }
        } else if lifecycle == .active {
            partialTranscript = update.text
        }
        return nil
    }

    public mutating func switchDestination(to destination: VoiceDestination) {
        self.destination = destination
    }

    public mutating func commit(hasAttachments: Bool = false) -> VoiceCommitAction? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        lifecycle = .stopped
        isEngineReady = false
        switch destination {
        case .agent:
            guard !text.isEmpty || hasAttachments else { return nil }
            return .sendAgent(text)
        case .terminal:
            guard !text.isEmpty else { return nil }
            return .executeTerminal(text)
        }
    }

    public mutating func clearAfterSuccessfulCommit() {
        draft = ""
        partialTranscript = ""
        draftAtStart = ""
        acceptsLateFinal = false
        provisionalPhrase = nil
        lifecycle = .stopped
        isEngineReady = false
        activeTurn = nil
        lateFinalTurn = nil
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
        let normalized = identifier.replacingOccurrences(of: "_", with: "-")
        if normalized.lowercased().hasPrefix("zh-hans") {
            return "zh-CN"
        }
        return normalized
    }

    public static func choices(deviceLocale: String, firstClass: [String] = firstClassLocales) -> [String] {
        let device = normalize(deviceLocale)
        var identifiers = firstClass
        if !identifiers.contains(device) { identifiers.insert(device, at: 0) }
        return identifiers
    }
}
