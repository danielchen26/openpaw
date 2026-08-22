import AVFoundation
import Foundation
import OpenPawUI
import ParakeetASR
import Qwen3ASR

/// Push-to-talk backed by a speech model that lives on this phone.
///
/// Exists because Apple's recogniser cannot hear this product's core sentence. Measured by `tools/dictation-cer`,
/// `SFSpeechRecognizer` turns "运行 npm install 安装依赖" into "运行BPM in so安装" — 44% of the characters wrong,
/// and the part it destroys is the command name, which is the only part that has to be exact. Qwen3-ASR gets that
/// sentence right. A terminal client for bilingual developers that mishears every second command is not usable,
/// and no amount of UI work fixes it.
///
/// The shape is different from `SpeechDictation` in one way that reaches the UI: there are no partial results.
/// These models transcribe a complete recording, so the audio is buffered while the finger is down and handed over
/// whole on release. `deliversFinalAfterStop` tells the push-to-talk controller to wait for that answer instead of
/// committing the empty string it would otherwise find.
final class LocalASRDictation: DictationEngine {

    private let choice: DictationEngineChoice
    private let store: LocalASRModelStore
    private let session = LocalASRSession()

    init(choice: DictationEngineChoice, store: LocalASRModelStore) {
        self.choice = choice
        self.store = store
    }

    /// Available only once the weights are on disk. Reported honestly so the hold reports "no engine" rather than
    /// arming a ring over a model that cannot answer.
    var isAvailable: Bool {
        MainActor.assumeIsolated { store.state(of: choice).isInstalled }
    }

    var deliversFinalAfterStop: Bool { true }

    func transcribe(locale: Locale, mode: DictationMode) -> AsyncThrowingStream<DictationUpdate, any Error> {
        AsyncThrowingStream { continuation in
            let session = session
            let choice = choice
            let store = store
            let task = Task {
                do {
                    let turn = await session.beginTurn()
                    try await session.startRecording(turn: turn)
                    // Recording continues until `stop()`, which returns the samples. Waiting here rather than
                    // polling keeps the microphone's lifetime tied to the finger, not to a timer.
                    let samples = await session.awaitRecording(turn: turn)
                    guard !Task.isCancelled, !samples.isEmpty else {
                        continuation.finish()
                        return
                    }
                    let model = try await store.loadedModel(for: choice)
                    let text = try await model.transcribe(samples: samples, locale: locale, mode: mode)
                    continuation.yield(DictationUpdate(text: text, isFinal: true))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func stop() async {
        await session.stopRecording()
    }
}

// MARK: - Errors

enum LocalASRError: LocalizedError {
    case notDownloaded(String)
    case simulatorUnsupported
    case microphoneDenied
    case audioSessionFailed(String)
    case audioEngineFailed(String)

    var errorDescription: String? {
        switch self {
        case .notDownloaded(let name):
            "\(name) has not been downloaded yet. Download it in Settings › Dictation, or switch back to Apple."
        case .simulatorUnsupported:
            "Local speech models need a real device. The simulator has no GPU they can run on, so use Apple's "
                + "recogniser here and test the local ones on a phone."
        case .microphoneDenied:
            "OpenPaw cannot use the microphone. Turn it on in Settings › Privacy & Security › Microphone."
        case .audioSessionFailed(let detail):
            "The audio session could not start (\(detail)). End any call or recording and try again."
        case .audioEngineFailed(let detail):
            "The microphone could not start (\(detail)). Try again, or type instead."
        }
    }
}

// MARK: - Recording

/// Owns the microphone and accumulates 16 kHz mono samples for one utterance.
///
/// An actor because the audio graph is one mutable resource and a fast second hold would otherwise install a
/// second tap on the same input node, which throws inside CoreAudio.
///
/// Note that no speech recognition permission is requested here: these models are ours, running in this process, so
/// `SFSpeechRecognizer`'s authorisation — which exists because Apple's recogniser may send audio to Apple — does not
/// apply. Only the microphone is asked for.
private actor LocalASRSession {

    /// What the models want. Both Qwen3-ASR and Parakeet expect 16 kHz mono float, and converting once here is
    /// cheaper and more predictable than handing them a 48 kHz device format to resample per utterance.
    static let targetSampleRate: Double = 16_000
    /// A ceiling on one hold, so a phone left face-down with a finger on it cannot grow an unbounded buffer.
    /// Two minutes of 16 kHz float is about 7.7 MB.
    static let maximumSamples = Int(targetSampleRate) * 120

    private let audioEngine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private var isRecording = false
    private var generation = 0
    private var activeTurn: Int?
    private var waiters: [CheckedContinuation<[Float], Never>] = []

    func beginTurn() -> Int {
        generation += 1
        return generation
    }

    func startRecording(turn: Int) async throws {
        if isRecording { await stopRecording() }
        try await requestMicrophonePermission()
        try Task.checkCancellation()
        guard turn == generation else { throw CancellationError() }

        let session = AVAudioSession.sharedInstance()
        do {
            // `.record` with `.measurement`: this app plays nothing, and the processing chain that
            // `.default` mode applies gates and compresses speech before a model that was trained on raw audio
            // ever sees it.
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw LocalASRError.audioSessionFailed(error.localizedDescription)
        }

        let input = audioEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            deactivate()
            throw LocalASRError.audioEngineFailed("no input format")
        }
        guard
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Self.targetSampleRate,
                channels: 1,
                interleaved: false),
            let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        else {
            deactivate()
            throw LocalASRError.audioEngineFailed("cannot convert \(inputFormat.sampleRate) Hz to 16 kHz mono")
        }
        self.converter = converter

        samples = []
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            // Converted on the audio thread rather than stored raw and converted later: keeping 48 kHz stereo for
            // two minutes costs six times the memory, and the conversion is cheap compared with the model.
            let converted = LocalASRSession.convert(buffer: buffer, using: converter, to: targetFormat)
            guard !converted.isEmpty else { return }
            Task { await self.append(converted) }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            deactivate()
            throw LocalASRError.audioEngineFailed(error.localizedDescription)
        }

        isRecording = true
        activeTurn = turn
    }

    /// Suspends until the finger comes up, then hands over everything that was recorded.
    func awaitRecording(turn: Int) async -> [Float] {
        guard turn == activeTurn, isRecording else { return samples }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func stopRecording() async {
        guard isRecording else {
            // A stop with nothing running still has to release anyone waiting, or the transcribe task hangs until
            // the push-to-talk timeout instead of finishing immediately.
            resumeWaiters()
            return
        }
        isRecording = false
        activeTurn = nil

        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.reset()
        converter = nil
        deactivate()
        resumeWaiters()
    }

    private func append(_ newSamples: [Float]) {
        guard isRecording, samples.count < Self.maximumSamples else { return }
        samples.append(contentsOf: newSamples.prefix(Self.maximumSamples - samples.count))
    }

    private func resumeWaiters() {
        let recorded = samples
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume(returning: recorded) }
    }

    private func deactivate() {
        // Never thrown onward: the graph is already down, and failing to deactivate must not be reported as a
        // dictation failure when the user's words were captured fine.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func requestMicrophonePermission() async throws {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return
        case .denied:
            throw LocalASRError.microphoneDenied
        case .undetermined:
            let granted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            }
            guard granted else { throw LocalASRError.microphoneDenied }
        @unknown default:
            throw LocalASRError.microphoneDenied
        }
    }

    /// Device format to 16 kHz mono float, one tap buffer at a time.
    ///
    /// `nonisolated static` so it can run on the audio thread without hopping onto the actor: the tap callback is
    /// real-time and an actor hop there would drop buffers.
    nonisolated private static func convert(
        buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, to format: AVAudioFormat
    ) -> [Float] {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1_024)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return [] }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            // The converter asks repeatedly until it has enough input; answering with the same buffer twice would
            // duplicate audio, so the second ask is told the stream is dry.
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

// MARK: - Loaded models

/// A model that has been loaded into memory and can transcribe.
///
/// Wrapped in an actor because neither `Qwen3ASRModel` nor `ParakeetASRModel` is thread-safe — both say so in
/// their own documentation — and dictation can be triggered again while a previous transcription is still running.
actor LoadedASRModel {

    private enum Backend {
        case qwen(Qwen3ASRModel)
        case parakeet(ParakeetASRModel)
    }

    private let backend: Backend

    init(qwen: Qwen3ASRModel) { backend = .qwen(qwen) }
    init(parakeet: ParakeetASRModel) { backend = .parakeet(parakeet) }

    func transcribe(samples: [Float], locale: Locale, mode: DictationMode) throws -> String {
        switch backend {
        case .qwen(let model):
            // The language hint is given rather than left to auto-detect: the user already told us which language
            // they are dictating in, and a wrong guess on a short mixed utterance is the failure mode that made
            // this whole engine necessary.
            let options = Qwen3DecodingOptions(language: Self.languageCode(locale))
            return Self.clean(model.transcribe(
                audio: samples, sampleRate: Int(LocalASRSession.targetSampleRate), options: options))
        case .parakeet(let model):
            let text = try model.transcribeAudio(
                samples, sampleRate: Int(LocalASRSession.targetSampleRate),
                language: Self.languageCode(locale))
            return Self.clean(text)
        }
    }

    /// ISO language subtag, which is what both models want. `zh-Hans-CN` and `zh_CN` both mean "zh".
    private static func languageCode(_ locale: Locale) -> String? {
        locale.language.languageCode?.identifier
    }

    /// Strips the tags a model may emit around its own output.
    ///
    /// A transcript that arrives with `<|zh|>` on the front is not a transcript, it is a debug string, and it would
    /// be pasted straight into a terminal draft.
    private static func clean(_ text: String) -> String {
        text
            .replacingOccurrences(of: "<[^>]{0,40}>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<\\|[^|]{0,40}\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
