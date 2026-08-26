import CoreGraphics
import Foundation

/// App-wide push-to-talk, owned by the model so the ring is drawn once at the root and the transcript is
/// available to whichever screen the user is on when they let go.
///
/// Living on the model rather than in a view is what makes "hold anywhere" mean anywhere: a per-screen
/// implementation would need the gesture, the ring and the engine plumbing repeated on every destination, and
/// would still lose the recording when a screen changed underneath it.
@MainActor
@Observable
public final class PushToTalkController {

    public private(set) var state = PushToTalk()
    /// What has been heard so far in this hold. Editable text goes to the screen that claims it on release.
    public private(set) var transcript = ""
    public private(set) var isUnavailable = false
    /// The finger is up and a whole-utterance local model is still turning the recording into words.
    ///
    /// Streaming recognisers may also reconcile a final word after release, but that short drain keeps the normal
    /// listening presentation. This visible state is reserved for downloaded Qwen3 or Parakeet models, which produce
    /// their only answer after the microphone closes and may take long enough to need explicit feedback.
    public private(set) var isTranscribing = false

    /// How long the wait for a non-streaming model's answer may last before the utterance is abandoned.
    ///
    /// Generous, because a 1.7B model on a cold cache is genuinely slow, and bounded, because a model that wedged
    /// must not leave the UI claiming to be transcribing for the rest of the session.
    static let finalizeTimeout: Duration = .seconds(20)

    /// Set by the screen currently on top. Release delivers the transcript here.
    public var onCommit: ((String) -> Void)?
    /// Recognition failures must be visible. A silent error looks exactly like a dead microphone.
    public var onFailure: (((any Error)) -> Void)?

    /// Words that were spoken while no screen was listening.
    ///
    /// The gesture is installed app-wide, so a user can hold and speak on Chat, Settings or the repo browser —
    /// screens with nowhere to put a terminal draft. Dropping the sentence there would mean the ring armed, the
    /// user spoke, and nothing happened, which is the failure this whole feature exists to avoid. Held instead,
    /// so a screen that can use it may take it, and so the root can tell the user it was heard.
    public private(set) var unclaimed: String?

    /// Takes the held words, if any. Claiming empties the store: the draft owns them now, and holding again must
    /// not reinsert the previous sentence.
    @discardableResult
    public func claim() -> String? {
        defer { unclaimed = nil }
        return unclaimed
    }

    private var engine: (any DictationEngine)?
    private var locale: Locale = .current
    private var mode: DictationMode = .composer
    private var listenTask: Task<Void, Never>?
    private var transcription: DictationTranscription?
    private var transcriptionGeneration = 0
    private var armTask: Task<Void, Never>?
    /// The wait for a non-streaming model's answer after the microphone closed.
    private var finalizeTask: Task<Void, Never>?
    private let clock = ContinuousClock()

    public init() {}

    public func configure(engine: (any DictationEngine)?, locale: Locale, mode: DictationMode) {
        self.engine = engine
        self.locale = locale
        self.mode = mode
    }

    public var ring: TouchRingPresentation? { TouchRingPresentation(state) }

    /// A finger went down. The ring appears immediately, before the hold has armed, so the press is visibly
    /// acknowledged rather than seeming to do nothing for a third of a second.
    public func touchBegan(at point: CGPoint) {
        guard engine?.isAvailable == true else {
            isUnavailable = true
            return
        }
        isUnavailable = false
        state.touchBegan(at: point)
    }

    /// The hold threshold elapsed. Recognition starts here, not on touch down: starting on every tap would open
    /// the microphone dozens of times a minute and make the first word of a real utterance arrive late.
    public func arm() {
        guard state.holdElapsed(at: clock.now), let engine else { return }
        // A new hold supersedes a pending finalize: the previous sentence had its chance, and leaving that task to
        // fire later would drop stale words into the draft the user is speaking into now.
        finalizeTask?.cancel()
        finalizeTask = nil
        isTranscribing = false
        let previousTranscription = transcription
        let previousListening = listenTask
        previousListening?.cancel()
        Task { await previousTranscription?.stop() }
        transcript = ""
        transcriptionGeneration += 1
        let generation = transcriptionGeneration
        let transcription = engine.transcribe(locale: locale, mode: mode)
        self.transcription = transcription
        listenTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await update in transcription.updates {
                    guard !Task.isCancelled else { return }
                    guard self.transcriptionGeneration == generation else { return }
                    self.transcript = update.text
                }
            } catch is CancellationError {
                // Discarding or replacing a turn cancels its consumer. That is a normal lifecycle end.
            } catch {
                self.transcript = ""
                self.onFailure?(error)
            }
        }
    }

    public func touchMoved(to point: CGPoint) {
        state.touchMoved(to: point, slop: PushToTalk.slop)
        if case .idle = state.phase { cancelListening() }
    }

    /// The finger came up. Whether anything is delivered depends on how long the microphone was actually open.
    public func touchEnded() {
        let release = state.touchEnded(at: clock.now)
        switch release {
        case .nothingToDo:
            stopEngine()
        case .discard:
            // Too short to have said anything. Delivering it would insert a stray word into a terminal draft.
            stopEngine()
            transcript = ""
        case .commit:
            // Even a streaming recogniser may reconcile its last or only word after the microphone closes. Draining
            // the owned stream avoids turning a short utterance into an empty commit while still bounding a wedged
            // recogniser below.
            finalizeAfterStop()
        }
    }

    /// Closes the microphone and waits for the stream's final answer, then delivers it.
    ///
    /// The listening task is left running on purpose — it is the thing that will receive the final update — and is
    /// only torn down once the answer arrives, the engine gives up, or the timeout fires.
    private func finalizeAfterStop() {
        isTranscribing = engine?.deliversFinalAfterStop == true
        let listening = listenTask
        let transcription = transcription
        let generation = transcriptionGeneration
        let timeout: Duration = engine?.deliversFinalAfterStop == true ? Self.finalizeTimeout : .seconds(2)
        armTask?.cancel()
        armTask = nil
        finalizeTask?.cancel()
        finalizeTask = Task { [weak self] in
            await transcription?.stopAndWait(for: listening, timeout: timeout)
            guard let self, !Task.isCancelled, self.transcriptionGeneration == generation else { return }
            self.listenTask = nil
            self.transcription = nil
            self.isTranscribing = false
            // On timeout the consumer is cancelled, but whatever partial text already arrived is still delivered: a
            // slow recogniser and a wedged one look the same here, and throwing away heard words is the worse error.
            self.deliver(self.transcript)
            self.transcript = ""
        }
    }

    /// Hands finished words to the screen that asked for them, or holds them for one that can.
    private func deliver(_ heard: String) {
        let text = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let onCommit {
            onCommit(text)
        } else {
            unclaimed = text
        }
    }

    /// A call arrived, or the app went to the background. Never delivers: no one chose to stop speaking.
    public func cancel() {
        state.cancel()
        transcript = ""
        isTranscribing = false
        finalizeTask?.cancel()
        finalizeTask = nil
        stopEngine()
    }

    private func cancelListening() {
        transcript = ""
        stopEngine()
    }

    private func stopEngine() {
        armTask?.cancel()
        armTask = nil
        let task = listenTask
        listenTask = nil
        let transcription = transcription
        self.transcription = nil
        transcriptionGeneration += 1
        task?.cancel()
        Task {
            await transcription?.stop()
        }
    }
}
