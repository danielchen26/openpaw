import Foundation
import Testing

@testable import OpenPawUI

/// The controller is what turns a finger on the glass into words in a draft. `PushToTalkTests` covers the state
/// machine on its own; this covers the part that owns a microphone, because a hold that draws a perfect ring and
/// never opens the engine looks identical on a screenshot.
@MainActor
@Suite("Push to talk controller")
struct PushToTalkControllerTests {

    /// Waits for an async hand-off rather than counting `Task.yield()`s.
    ///
    /// Recognition arrives through a stream on another task, so a fixed number of yields is a guess about
    /// scheduling that fails under parallel test load and makes a real assertion look flaky.
    private func until(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("holding past the threshold actually opens the microphone")
    func armStartsTheEngine() async {
        // The ring appeared on the simulator while nothing was listening, which is exactly what a user would
        // report as "I held it and it drew a circle and then nothing happened".
        let engine = FakeEngine()
        let controller = PushToTalkController()
        controller.configure(engine: engine, locale: Locale(identifier: "en-US"), mode: .terminal)

        controller.touchBegan(at: CGPoint(x: 100, y: 200))
        #expect(await engine.startCount == 0, "a touch is not a hold; the microphone waits")

        controller.arm()
        await until { engine.startedNow }
        #expect(await engine.startCount == 1)
        #expect(await engine.requestedModes == [.terminal])
    }

    @Test("releasing after a real utterance delivers what was heard")
    func releaseCommitsTheTranscript() async {
        let engine = FakeEngine()
        let controller = PushToTalkController()
        controller.configure(engine: engine, locale: Locale(identifier: "en-US"), mode: .terminal)

        var committed: [String] = []
        controller.onCommit = { committed.append($0) }

        controller.touchBegan(at: CGPoint(x: 100, y: 200))
        controller.arm()
        await engine.emit("git status")
        await until { !controller.transcript.isEmpty }
        #expect(controller.transcript == "git status")

        // Long enough to be an utterance rather than a slip.
        try? await Task.sleep(for: PushToTalk.minimumUtterance + .milliseconds(60))
        controller.touchEnded()

        #expect(committed == ["git status"])
        #expect(controller.transcript.isEmpty, "the draft owns the text now; holding it twice would double it")
        await until { engine.stoppedNow }
        #expect(await engine.stopCount == 1, "the microphone must close when the finger comes up")
    }

    @Test("a slip of the finger says nothing")
    func tooShortToBeSpeechIsDiscarded() async {
        let engine = FakeEngine()
        let controller = PushToTalkController()
        controller.configure(engine: engine, locale: Locale(identifier: "en-US"), mode: .terminal)

        var committed: [String] = []
        controller.onCommit = { committed.append($0) }

        controller.touchBegan(at: CGPoint(x: 10, y: 10))
        controller.arm()
        await engine.emit("uh")
        controller.touchEnded()

        // Releasing immediately is a slip. Delivering it would drop a stray word into a terminal draft, which is
        // worse than losing a word the user never meant to say.
        #expect(committed.isEmpty)
        #expect(controller.transcript.isEmpty)
    }

    @Test("words spoken on a screen that cannot take them are kept, not dropped")
    func unclaimedSpeechIsRetained() async {
        // "Hold anywhere" installs the gesture app-wide, but only the terminal claims the text. On Chat or
        // Settings a user would hold, watch the ring arm, speak, let go, and have the sentence disappear.
        // Nothing may silently discard something a person said out loud.
        let engine = FakeEngine()
        let controller = PushToTalkController()
        controller.configure(engine: engine, locale: .current, mode: .terminal)
        controller.onCommit = nil

        controller.touchBegan(at: CGPoint(x: 30, y: 30))
        controller.arm()
        await engine.emit("open the repo screen")
        await until { !controller.transcript.isEmpty }
        try? await Task.sleep(for: PushToTalk.minimumUtterance + .milliseconds(60))
        controller.touchEnded()

        #expect(controller.unclaimed == "open the repo screen")

        // Once a screen takes it, it is gone from here: the draft owns the words and holding again must not
        // reinsert the previous sentence.
        #expect(controller.claim() == "open the repo screen")
        #expect(controller.unclaimed == nil)
        #expect(controller.claim() == nil)
    }

    @Test("a second sentence does not delete the first one nobody has claimed yet")
    func consecutiveUtterancesAccumulate() async {
        // Speaking twice on a screen that stages rather than executes is normal: correct yourself, add a flag.
        // Replacing the slot would lose the first sentence with no way to get it back.
        let engine = FakeEngine()
        let controller = PushToTalkController()
        controller.configure(engine: engine, locale: .current, mode: .terminal)

        var staged: String?
        controller.onCommit = { text in
            staged = staged.map { $0 + " " + text } ?? text
        }

        for phrase in ["git status", "--short"] {
            controller.touchBegan(at: CGPoint(x: 30, y: 30))
            controller.arm()
            await engine.emit(phrase)
            await until { controller.transcript == phrase }
            try? await Task.sleep(for: PushToTalk.minimumUtterance + .milliseconds(60))
            controller.touchEnded()
        }

        #expect(staged == "git status --short")
    }

    @Test("no engine means the hold reports itself unavailable instead of drawing a dead ring")
    func unavailableEngineIsSurfaced() {
        let controller = PushToTalkController()
        controller.configure(engine: nil, locale: .current, mode: .terminal)

        controller.touchBegan(at: CGPoint(x: 5, y: 5))

        #expect(controller.isUnavailable)
        #expect(controller.ring == nil, "a ring that cannot listen is a lie about what is happening")
    }

    @Test("backgrounding mid-sentence delivers nothing")
    func cancelNeverCommits() async {
        let engine = FakeEngine()
        let controller = PushToTalkController()
        controller.configure(engine: engine, locale: .current, mode: .terminal)

        var committed: [String] = []
        controller.onCommit = { committed.append($0) }

        controller.touchBegan(at: CGPoint(x: 40, y: 40))
        controller.arm()
        await engine.emit("rm -rf something")
        try? await Task.sleep(for: PushToTalk.minimumUtterance + .milliseconds(60))

        // A phone call took the microphone. Nobody chose to stop speaking, so nobody chose to send this.
        controller.cancel()

        #expect(committed.isEmpty)
        #expect(controller.transcript.isEmpty)
        #expect(controller.ring == nil)
    }
}

private actor FakeEngine: DictationEngine {
    nonisolated var isAvailable: Bool { true }
    private(set) var requestedModes: [DictationMode] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var continuation: AsyncThrowingStream<DictationUpdate, any Error>.Continuation?

    nonisolated func transcribe(locale: Locale, mode: DictationMode)
        -> AsyncThrowingStream<DictationUpdate, any Error>
    {
        AsyncThrowingStream { continuation in
            Task { await self.began(mode: mode, continuation: continuation) }
        }
    }

    func stop() async {
        stopCount += 1
        stopped.set()
        continuation?.finish()
    }

    /// Non-isolated peeks so a test can wait on the actor without serialising behind its own await.
    nonisolated let started = Flag()
    nonisolated let stopped = Flag()
    nonisolated var startedNow: Bool { started.value }
    nonisolated var stoppedNow: Bool { stopped.value }

    func emit(_ text: String) async {
        for _ in 0..<200 where continuation == nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
        continuation?.yield(DictationUpdate(text: text, isFinal: false))
    }

    private func began(
        mode: DictationMode, continuation: AsyncThrowingStream<DictationUpdate, any Error>.Continuation
    ) {
        startCount += 1
        started.set()
        requestedModes.append(mode)
        self.continuation = continuation
    }
}

/// A one-way flag readable without entering the actor, so a test can poll for a hand-off it is waiting on.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    var value: Bool { lock.withLock { raised } }
    func set() { lock.withLock { raised = true } }
}
