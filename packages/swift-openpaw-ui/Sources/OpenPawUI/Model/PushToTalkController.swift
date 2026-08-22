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
    /// The finger is up and a local model is still turning the recording into words.
    ///
    /// Only ever true for an engine that does not stream. Apple's recogniser has already produced text by the time
    /// the finger lifts, so it commits immediately and this stays false; a downloaded Qwen3 or Parakeet model does
    /// the whole utterance at once after the microphone closes, and without a state for that the user would let go
    /// and watch nothing happen for a second, which reads as a dropped sentence.
    public private(set) var isTranscribing = false

    /// How long the wait for a non-streaming model's answer may last before the utterance is abandoned.
    ///
    /// Generous, because a 1.7B model on a cold cache is genuinely slow, and bounded, because a model that wedged
    /// must not leave the UI claiming to be transcribing for the rest of the session.
    static let finalizeTimeout: Duration = .seconds(20)

    /// Set by the screen currently on top. Release delivers the transcript here.
    public var onCommit: ((String) -> Void)?

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
        transcript = ""
        listenTask?.cancel()
        listenTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await update in engine.transcribe(locale: locale, mode: mode) {
                    guard !Task.isCancelled else { return }
                    self.transcript = update.text
                }
            } catch is CancellationError {
                // Releasing the finger cancels the stream. That is the normal end of every utterance.
            } catch {
                self.transcript = ""
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
        let heard = transcript
        switch release {
        case .nothingToDo:
            stopEngine()
        case .discard:
            // Too short to have said anything. Delivering it would insert a stray word into a terminal draft.
            stopEngine()
            transcript = ""
        case .commit:
            // A whole-utterance model has produced nothing yet: its words exist only after the microphone closes,
            // so the commit waits for the stream to finish rather than delivering the empty string it has now.
            if engine?.deliversFinalAfterStop == true {
                finalizeAfterStop()
            } else {
                stopEngine()
                deliver(heard)
                transcript = ""
            }
        }
    }

    /// Closes the microphone and waits for the model's one answer, then delivers it.
    ///
    /// The listening task is left running on purpose — it is the thing that will receive the final update — and is
    /// only torn down once the answer arrives, the engine gives up, or the timeout fires.
    private func finalizeAfterStop() {
        isTranscribing = true
        let listening = listenTask
        let engine = engine
        armTask?.cancel()
        armTask = nil
        finalizeTask?.cancel()
        finalizeTask = Task { [weak self] in
            await engine?.stop()
            // The stream ends when the engine emits its final text; `listenTask` has been writing each update into
            // `transcript`, so awaiting its completion is how the last one is picked up.
            let waited: Void? = try? await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { _ = await listening?.value }
                group.addTask {
                    try await Task.sleep(for: PushToTalkController.finalizeTimeout)
                    throw CancellationError()
                }
                defer { group.cancelAll() }
                return try await group.next()
            }
            guard let self, !Task.isCancelled else { return }
            listening?.cancel()
            self.listenTask = nil
            self.isTranscribing = false
            // `waited == nil` means the timeout won. Whatever partial text exists is still delivered: a model that
            // answered slowly and a model that hung look the same from here, and throwing away words the user said
            // is the worse of the two mistakes.
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
        let engine = engine
        Task {
            await engine?.stop()
            // The engine emits a final result after `stop`, so the stream is given a moment to deliver it before
            // being torn down. Cancelling immediately loses the last words of every utterance.
            try? await Task.sleep(for: .milliseconds(50))
            task?.cancel()
        }
    }
}
