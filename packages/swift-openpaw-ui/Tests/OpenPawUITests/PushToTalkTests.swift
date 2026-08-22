import CoreGraphics
import Testing

@testable import OpenPawUI

/// Hold anywhere to talk, release to finish. The failures worth testing are the ones that are invisible: a hold
/// that steals a scroll, a release that commits nothing, a lift that leaves the microphone running.
@Suite("Push to talk")
struct PushToTalkTests {

    private let origin = CGPoint(x: 200, y: 400)
    private let clock = ContinuousClock()

    @Test("holding arms the microphone, releasing finishes the utterance")
    func holdThenReleaseCommits() {
        var talk = PushToTalk()
        let start = clock.now

        talk.touchBegan(at: origin)
        #expect(!talk.isListening, "the microphone must not open before the hold threshold")

        talk.holdElapsed(at: start)
        #expect(talk.isListening)

        // A second of speech is an utterance by any measure.
        let release = talk.touchEnded(at: start.advanced(by: .seconds(1)))
        #expect(release == .commit)
        #expect(!talk.isListening, "releasing must always close the microphone")
    }

    @Test("a scroll is not speech")
    func draggingCancelsAPendingHold() {
        var talk = PushToTalk()
        talk.touchBegan(at: origin)

        // A flick to scroll the terminal. If this armed the microphone, the app would listen every time the user
        // read back through their scrollback.
        talk.touchMoved(to: CGPoint(x: origin.x, y: origin.y - 60), slop: 12)

        #expect(talk.touchPoint == nil, "a drag left a ring on screen")
        let armedAfterDrag = talk.holdElapsed(at: clock.now)
        #expect(!armedAfterDrag, "a cancelled hold must not arm later")
    }

    @Test("a finger that wanders while talking keeps talking")
    func movingWhileListeningKeepsListening() {
        var talk = PushToTalk()
        let start = clock.now
        talk.touchBegan(at: origin)
        talk.holdElapsed(at: start)

        // Once someone is speaking they stop watching their thumb. Cancelling here would cut them off mid-sentence.
        let moved = CGPoint(x: origin.x + 90, y: origin.y + 90)
        talk.touchMoved(to: moved, slop: 12)

        #expect(talk.isListening)
        #expect(talk.touchPoint == moved, "the ring must follow the finger")
    }

    @Test("a tap is not an utterance")
    func tooShortToHaveSaidAnything() {
        var talk = PushToTalk()
        let start = clock.now
        talk.touchBegan(at: origin)
        talk.holdElapsed(at: start)

        // Armed, then released almost immediately: recognition has produced nothing, so committing would insert
        // an empty draft and flash the UI for no reason.
        let release = talk.touchEnded(at: start.advanced(by: .milliseconds(80)))
        #expect(release == .discard)
    }

    @Test("a tap that never armed belongs to whatever is under the finger")
    func releasingWithoutArmingDoesNothing() {
        var talk = PushToTalk()
        talk.touchBegan(at: origin)

        // This is the common case: every tap on a button in the app ends here, and must not touch dictation.
        let release = talk.touchEnded(at: clock.now)
        #expect(release == .nothingToDo)
    }

    @Test("the system taking the touch never counts as something said")
    func systemCancellationDiscards() {
        var talk = PushToTalk()
        talk.touchBegan(at: origin)
        talk.holdElapsed(at: clock.now)

        // A phone call, or the app going to the background. No one decided to stop speaking.
        talk.cancel()
        #expect(!talk.isListening, "the microphone was left open after the system cancelled the touch")
        #expect(talk.touchPoint == nil)
    }

    @Test("the hold is faster than a long press but slower than a scroll")
    func holdThresholdIsInTheUsableBand() {
        // Below ~200ms holds start stealing scrolls; Apple's 500ms long press is sluggish for the primary path.
        #expect(PushToTalk.holdThreshold >= .milliseconds(200))
        #expect(PushToTalk.holdThreshold <= .milliseconds(350))
    }

    @Test("no screen may claim a long press that would steal the speech hold")
    func screenLongPressesDoNotStealTheHold() {
        // Found on the device, not in a test: holding the terminal opened its select/copy menu and the speech
        // ring never appeared, because that menu answered a 0.45s long press while speech arms at 0.28s.
        #expect(PushToTalk.conflictsWithSpeech(longPress: .milliseconds(450)))
        #expect(PushToTalk.conflictsWithSpeech(longPress: PushToTalk.holdThreshold))

        // A screen may still have its own long press if it waits until well after speech has armed, so the user
        // sees the ring first and learns the two are different gestures.
        #expect(!PushToTalk.conflictsWithSpeech(longPress: .milliseconds(900)))
        #expect(PushToTalk.reservedForSpeech > PushToTalk.holdThreshold)
    }

    // MARK: The ring

    @Test("there is no ring when nothing is happening")
    func noRingWhenIdle() {
        #expect(TouchRingPresentation(PushToTalk()) == nil)
    }

    @Test("the ring shows where the finger is and whether the microphone is live")
    func ringGrowsWhenArmed() throws {
        var talk = PushToTalk()
        talk.touchBegan(at: origin)

        let pending = try #require(TouchRingPresentation(talk))
        #expect(pending.center == origin)
        #expect(!pending.isArmed)

        talk.holdElapsed(at: clock.now)
        let armed = try #require(TouchRingPresentation(talk))
        // The size change is the only signal that the microphone opened, since the user is looking at their thumb.
        #expect(armed.diameter > pending.diameter)
        #expect(armed.isArmed)
        #expect(armed.accessibilityLabel == "Listening. Release to finish.")
    }
}
