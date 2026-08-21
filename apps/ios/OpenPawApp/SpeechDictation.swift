import AVFoundation
import Foundation
import OpenPawUI
import Speech

/// On-device dictation, push-to-talk.
///
/// Push-to-talk rather than always-listening is a privacy decision, not a UI one: the audio graph only exists
/// between the moment the user's finger lands on the button and the moment it lifts, so there is no state in which
/// this app is holding a live microphone tap that the user did not ask for. `stop()` tears the graph down rather
/// than pausing it, which is why it is `async` — the teardown is ordered and has to finish before the audio session
/// is handed back to whatever was playing.
final class SpeechDictation: DictationEngine {

    /// The locales the product treats as first class. Both are real defaults for this product's users, and neither is
    /// a fallback for the other — a Simplified Chinese speaker dictating a prompt is not an edge case.
    static let firstClassLocales: [Locale] = [
        Locale(identifier: "en-US"),
        Locale(identifier: "zh-CN"),
    ]

    /// Locales offered in Settings: the two first-class ones, then whatever else the device supports, deduplicated
    /// and stable so the picker does not reorder itself between launches.
    static var offeredLocales: [Locale] {
        let supported = SFSpeechRecognizer.supportedLocales()
        var seen = Set<String>()
        var result: [Locale] = []
        for locale in firstClassLocales where supported.contains(where: { $0.identifier == locale.identifier }) {
            if seen.insert(locale.identifier).inserted { result.append(locale) }
        }
        for locale in supported.sorted(by: { $0.identifier < $1.identifier })
        where seen.insert(locale.identifier).inserted {
            result.append(locale)
        }
        return result
    }

    private let session = DictationSession()

    var isAvailable: Bool {
        guard SFSpeechRecognizer.authorizationStatus() != .restricted else { return false }
        return !SFSpeechRecognizer.supportedLocales().isEmpty
    }

    /// True when this locale can be recognised without sending audio off the device. Surfaced so Settings can say so
    /// plainly instead of the user having to guess.
    static func supportsOnDeviceRecognition(locale: Locale) -> Bool {
        SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition ?? false
    }

    func transcribe(locale: Locale, mode: DictationMode) -> AsyncThrowingStream<DictationUpdate, any Error> {
        AsyncThrowingStream { continuation in
            let session = session
            let task = Task<Int?, Never> {
                do {
                    let turn = await session.beginTurn()
                    return try await session.start(turn: turn, locale: locale, mode: mode, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                    return nil
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task {
                    guard let turn = await task.value else { return }
                    await session.stop(turn: turn)
                }
            }
        }
    }

    func stop() async {
        await session.stop()
    }
}

// MARK: - Errors

enum DictationError: LocalizedError, Equatable {
    case microphoneDenied
    case speechRecognitionDenied
    case localeUnsupported(String)
    case recognizerUnavailable(String)
    case audioSessionFailed(String)
    case audioEngineFailed(String)

    /// Errors say what happened and what to do. None of them apologise, and none of them are vague.
    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "OpenPaw cannot use the microphone. Turn it on in Settings › Privacy & Security › Microphone."
        case .speechRecognitionDenied:
            "OpenPaw cannot use speech recognition. Turn it on in Settings › Privacy & Security › Speech Recognition."
        case .localeUnsupported(let identifier):
            "This device cannot recognise \(identifier). Pick another dictation language in Settings."
        case .recognizerUnavailable(let identifier):
            "Speech recognition for \(identifier) is unavailable right now. Try again in a moment, or type instead."
        case .audioSessionFailed(let detail):
            "The audio session could not start (\(detail)). End any call or recording and try again."
        case .audioEngineFailed(let detail):
            "The microphone could not start (\(detail)). Try again, or type instead."
        }
    }
}

// MARK: - Session

/// Owns the audio graph. An actor because the graph is a single mutable resource that a fast double-tap on the
/// dictate button would otherwise start twice.
private actor DictationSession {

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var isRunning = false
    private var generation = 0
    private var activeTurn: Int?
    private var lateFinalTurn: Int?

    func beginTurn() -> Int {
        generation += 1
        let turn = generation
        lateFinalTurn = nil
        return turn
    }

    func start(
        turn: Int,
        locale: Locale,
        mode: DictationMode,
        continuation: AsyncThrowingStream<DictationUpdate, any Error>.Continuation
    ) async throws -> Int {
        // A second press while the first is still running restarts cleanly rather than stacking two taps on the
        // input node, which throws inside CoreAudio and leaves the session activated.
        if isRunning, let activeTurn { await stop(turn: activeTurn) }

        try await requestPermissions()

        try Task.checkCancellation()
        guard turn == generation else { throw CancellationError() }

        guard SFSpeechRecognizer.supportedLocales().contains(where: { $0.identifier == locale.identifier }) else {
            throw DictationError.localeUnsupported(locale.identifier)
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw DictationError.recognizerUnavailable(locale.identifier)
        }

        try Task.checkCancellation()
        guard turn == generation else { throw CancellationError() }

        self.recognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // On-device whenever the locale has a downloaded model. Both first-class locales do on a modern device, and
        // when one does not, the alternative is sending the user's voice to a server — so this is set from the
        // recogniser's own answer rather than from a build flag.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        // Punctuation is right for a prose prompt and wrong for a terminal: "dot" would become "." mid-command and
        // a trailing full stop would land on the command line.
        request.addsPunctuation = mode == .composer
        request.taskHint = mode == .composer ? .dictation : .unspecified
        if mode == .terminal {
            // Names the recogniser would otherwise render as English words. Short list on purpose: every entry costs
            // recognition accuracy elsewhere.
            request.contextualStrings = ["git", "npm", "pnpm", "cargo", "kubectl", "grep", "sudo", "OpenPaw"]
        }
        self.request = request

        try activateAudioSession()

        do {
            try Task.checkCancellation()
            guard turn == generation else { throw CancellationError() }
        } catch {
            deactivateAudioSession()
            throw error
        }

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            deactivateAudioSession()
            throw DictationError.audioEngineFailed("no input format")
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            deactivateAudioSession()
            throw DictationError.audioEngineFailed(error.localizedDescription)
        }

        isRunning = true
        activeTurn = turn
        lateFinalTurn = nil

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            let update = result.map {
                DictationUpdate(text: $0.bestTranscription.formattedString, isFinal: $0.isFinal)
            }
            Task { await self.deliver(update: update, error: error, turn: turn, continuation: continuation) }
        }
        return turn
    }

    func stop() async {
        guard let activeTurn else { return }
        await stop(turn: activeTurn)
    }

    func stop(turn: Int) async {
        guard turn == activeTurn else { return }
        guard isRunning || recognitionTask != nil || request != nil else { return }
        isRunning = false
        lateFinalTurn = turn
        activeTurn = nil

        // Order matters: pull the tap first so no more buffers arrive, then tell the recogniser the audio ended so it
        // emits its final result, then cancel, then release the session.
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.reset()

        request?.endAudio()
        request = nil

        recognitionTask?.finish()
        recognitionTask = nil
        recognizer = nil

        deactivateAudioSession()
    }

    private func deliver(
        update: DictationUpdate?,
        error: (any Error)?,
        turn: Int,
        continuation: AsyncThrowingStream<DictationUpdate, any Error>.Continuation
    ) {
        guard turn == activeTurn || update?.isFinal == true && turn == lateFinalTurn else { return }
        if let update {
            continuation.yield(update)
            if update.isFinal {
                if turn == lateFinalTurn { lateFinalTurn = nil }
                continuation.finish()
            }
        }
        if let error {
            // A cancellation after the final result is the normal end of a push-to-talk turn, not a failure, and
            // finishing twice is harmless — `AsyncThrowingStream` ignores the second.
            continuation.finish(throwing: error)
        }
    }

    // MARK: Permissions

    private func requestPermissions() async throws {
        // Microphone. `AVAudioApplication` is the iOS 17 replacement for the deprecated session-level call.
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            break
        case .denied:
            throw DictationError.microphoneDenied
        case .undetermined:
            let granted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            }
            guard granted else { throw DictationError.microphoneDenied }
        @unknown default:
            throw DictationError.microphoneDenied
        }

        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            break
        case .denied, .restricted:
            throw DictationError.speechRecognitionDenied
        case .notDetermined:
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            guard status == .authorized else { throw DictationError.speechRecognitionDenied }
        @unknown default:
            throw DictationError.speechRecognitionDenied
        }
    }

    // MARK: Audio session

    /// `.record` rather than `.playAndRecord`, because this app plays nothing and asking for playback would take the
    /// audio route from whatever the user is listening to. `.measurement` turns off the processing chain that would
    /// otherwise gate and compress speech before the recogniser sees it. `.duckOthers` lowers other audio instead of
    /// stopping it, so a podcast resumes at full volume the instant the button is released.
    private func activateAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw DictationError.audioSessionFailed(error.localizedDescription)
        }
    }

    private func deactivateAudioSession() {
        // Deliberately not throwing: the graph is already down, and a failure to deactivate must not be reported to
        // the user as a dictation error when their words were transcribed successfully.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
