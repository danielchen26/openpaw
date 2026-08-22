import AudioCommon
import Foundation
import OpenPawUI
import ParakeetASR
import Qwen3ASR

/// Downloads dictation model weights and keeps the loaded models.
///
/// Two jobs in one object on purpose: "is it downloaded" and "is it loaded" are the same question to a user
/// holding the screen and waiting for words, and splitting them across two types produced a settings screen that
/// said "Ready" while the first hold still took eleven seconds to answer.
@MainActor
@Observable
final class LocalASRModelStore: DictationModelInstalling {

    private var states: [DictationEngineChoice: DictationModelState] = [:]
    private var installs: [DictationEngineChoice: Task<Void, Never>] = [:]
    /// Models that have been loaded into memory this launch, keyed by engine.
    ///
    /// Kept rather than reloaded per utterance because loading a 4-bit 0.6B model takes seconds and dictation is
    /// supposed to feel like a walkie-talkie. Dropped on a memory warning, since a language model resident for a
    /// feature the user may not touch again this session is exactly what the system is asking to have back.
    private var loaded: [DictationEngineChoice: LoadedASRModel] = [:]
    private var loads: [DictationEngineChoice: Task<LoadedASRModel, any Error>] = [:]

    init() {
        for choice in DictationEngineChoice.allCases where choice.requiresDownload {
            states[choice] = Self.diskState(of: choice)
        }
    }

    func state(of choice: DictationEngineChoice) -> DictationModelState {
        guard choice.requiresDownload else { return .installed }
        return states[choice] ?? .absent
    }

    func install(_ choice: DictationEngineChoice) {
        guard choice.requiresDownload, installs[choice] == nil else { return }
        states[choice] = .downloading(progress: 0, detail: "Starting")
        // Progress arrives on whatever thread the downloader is using, so it is bounced back to the main actor.
        // Captured as its own closure rather than reaching for `self` inside the loading task, because that task
        // holds `self` weakly and a nested weak capture of an already-weak binding is not something the concurrency
        // checker will accept.
        let report: @Sendable (Double, String) -> Void = { [weak self] progress, detail in
            Task { @MainActor in
                guard let self, self.installs[choice] != nil else { return }
                self.states[choice] = .downloading(progress: progress, detail: detail)
            }
        }
        installs[choice] = Task { @MainActor [weak self] in
            do {
                // Loading is what downloads: both packages fetch missing weights inside `fromPretrained`, so a
                // separate download step would fetch the files and then throw away the loaded model.
                let model = try await Self.load(choice, progress: report)
                guard !Task.isCancelled else { return }
                self?.finishInstall(choice, model: model)
            } catch is CancellationError {
                self?.abandonInstall(choice)
            } catch {
                self?.failInstall(choice, reason: Self.shortReason(error))
            }
        }
    }

    func cancelInstall(of choice: DictationEngineChoice) {
        installs[choice]?.cancel()
        installs[choice] = nil
        // Partially fetched files are left on disk deliberately: `downloadWeights` skips what is already there, so
        // a resumed download continues rather than restarting a 1.9 GB transfer from zero.
        states[choice] = Self.diskState(of: choice)
    }

    func remove(_ choice: DictationEngineChoice) {
        installs[choice]?.cancel()
        installs[choice] = nil
        loads[choice]?.cancel()
        loads[choice] = nil
        loaded[choice] = nil
        if let modelID = choice.modelID,
            let directory = try? HuggingFaceDownloader.getCacheDirectory(for: modelID)
        {
            try? FileManager.default.removeItem(at: directory)
        }
        states[choice] = .absent
    }

    /// The model for this engine, loading it if this is the first utterance since launch.
    ///
    /// Concurrent callers share one load: a user who holds the screen twice in quick succession must not start two
    /// loads of the same multi-hundred-megabyte model.
    func loadedModel(for choice: DictationEngineChoice) async throws -> LoadedASRModel {
        if let model = loaded[choice] { return model }
        if let existing = loads[choice] { return try await existing.value }
        guard state(of: choice).isInstalled else {
            throw LocalASRError.notDownloaded(choice.displayName)
        }
        let task = Task { try await Self.load(choice, progress: nil) }
        loads[choice] = task
        do {
            let model = try await task.value
            loaded[choice] = model
            loads[choice] = nil
            return model
        } catch {
            loads[choice] = nil
            throw error
        }
    }

    /// Releases loaded weights. Called on a memory warning, where the alternative is the system killing the app
    /// while the user is in the middle of a session.
    func releaseLoadedModels() {
        loaded.removeAll()
    }

    // MARK: Install bookkeeping

    private func finishInstall(_ choice: DictationEngineChoice, model: LoadedASRModel) {
        installs[choice] = nil
        loaded[choice] = model
        states[choice] = .installed
    }

    private func abandonInstall(_ choice: DictationEngineChoice) {
        installs[choice] = nil
        states[choice] = Self.diskState(of: choice)
    }

    private func failInstall(_ choice: DictationEngineChoice, reason: String) {
        installs[choice] = nil
        states[choice] = .failed(reason)
    }

    // MARK: Loading

    private static func load(
        _ choice: DictationEngineChoice, progress: (@Sendable (Double, String) -> Void)?
    ) async throws -> LoadedASRModel {
        guard let modelID = choice.modelID else { throw LocalASRError.notDownloaded(choice.displayName) }
        // Both loaders take a plain, non-`Sendable` progress closure, so handing them one that is `Sendable`
        // still trips the concurrency checker at the call boundary. The value really is safe to send — it only
        // hops back to the main actor — and `nonisolated(unsafe)` is the narrowest way to say so, rather than
        // dropping progress reporting or making the whole store non-isolated.
        nonisolated(unsafe) let handler: ((Double, String) -> Void)? = progress.map { report in
            { fraction, detail in report(fraction, detail) }
        }
        switch choice {
        case .qwen3Small, .qwen3Large:
            let model = try await Qwen3ASRModel.fromPretrained(modelId: modelID, progressHandler: handler)
            return LoadedASRModel(qwen: model)
        case .parakeet:
            let model = try await ParakeetASRModel.fromPretrained(modelId: modelID, progressHandler: handler)
            return LoadedASRModel(parakeet: model)
        case .appleSpeech:
            throw LocalASRError.notDownloaded(choice.displayName)
        }
    }

    /// Whether this engine's weights are already on disk, asked of the same cache the loader will use.
    private static func diskState(of choice: DictationEngineChoice) -> DictationModelState {
        guard let modelID = choice.modelID,
            let directory = try? HuggingFaceDownloader.getCacheDirectory(for: modelID)
        else { return .absent }
        // `weightsExist` verifies every shard an index names, so a download killed half way reads as absent rather
        // than as a model that loads with random weights.
        return HuggingFaceDownloader.weightsExist(in: directory) ? .installed : .absent
    }

    /// One line a settings row can hold, rather than a CoreML stack trace.
    private static func shortReason(_ error: any Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return text.count > 120 ? String(text.prefix(117)) + "…" : text
    }
}

// MARK: - Engine construction

/// Builds the recogniser the user picked.
///
/// Engines are cached per choice because constructing one is cheap but not free, and because a fresh instance per
/// `configure` call would discard the audio session state the previous hold left behind.
@MainActor
final class LocalASREngineFactory: DictationEngineMaking {

    private let store: LocalASRModelStore
    private let apple: any DictationEngine
    private var localEngines: [DictationEngineChoice: LocalASRDictation] = [:]

    init(store: LocalASRModelStore, apple: any DictationEngine = SpeechDictation()) {
        self.store = store
        self.apple = apple
    }

    func engine(for choice: DictationEngineChoice) -> (any DictationEngine)? {
        switch choice {
        case .appleSpeech:
            return apple
        case .qwen3Small, .qwen3Large, .parakeet:
            // An engine whose weights are absent is not returned at all. Returning one would arm the ring, record
            // the user's sentence, and then throw — the words would be gone and the reason invisible.
            guard store.state(of: choice).isInstalled else { return nil }
            if let existing = localEngines[choice] { return existing }
            let engine = LocalASRDictation(choice: choice, store: store)
            localEngines[choice] = engine
            return engine
        }
    }
}
