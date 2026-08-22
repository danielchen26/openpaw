import CoreGraphics
import Foundation

/// Press and hold anywhere to talk.
///
/// Reaching a 44-point microphone button in the corner is the slowest possible way to start speaking, and it is
/// the thing this app is for. Holding a thumb wherever it already rests is the fastest, so the whole screen
/// becomes the button: hold to talk, release to stop, exactly like a walkie-talkie.
///
/// Modelled apart from the view because the parts that go wrong are not visual. A hold that fires while the user
/// is scrolling, a release that arrives before recognition started, and a lift that leaves the microphone running
/// are all state-machine bugs, and none of them can be caught by looking at the screen.
public struct PushToTalk: Sendable, Equatable {

    /// How long a touch must rest before it means speech.
    ///
    /// Short enough that talking feels immediate, long enough that a tap on the terminal, a scroll flick and a
    /// drag all complete before it fires. Apple's own long-press default is 0.5s, which is noticeably slow when
    /// it is the primary way into a feature; below about 0.2s scrolls start being stolen.
    public static let holdThreshold: Duration = .milliseconds(280)

    /// Points a finger may drift before a pending hold is treated as a scroll rather than speech.
    public static let slop: CGFloat = 12

    /// Long presses a screen may claim for itself without taking the hold away from speech.
    ///
    /// Holding anywhere is only "anywhere" if nothing else answers a long press first. The terminal used to open
    /// a select/copy menu at 0.45s, which fired after the speech hold armed and stole it: the ring never appeared
    /// and a menu did instead. A screen that wants its own long press has to ask for it well after speech has
    /// already claimed the gesture, or offer the action somewhere else.
    public static let reservedForSpeech: Duration = .milliseconds(900)

    /// Whether a screen-level long press at this duration would take the gesture away from dictation.
    public static func conflictsWithSpeech(longPress duration: Duration) -> Bool {
        duration < reservedForSpeech
    }

    /// A release this soon after the hold armed is treated as a slip, not an utterance.
    ///
    /// Recognition needs a moment to produce anything, so a 60ms press yields an empty transcript and a flash of
    /// UI. Discarding it is honest: nothing was said.
    public static let minimumUtterance: Duration = .milliseconds(350)

    public enum Phase: Sendable, Equatable {
        /// Nothing is happening.
        case idle
        /// A finger is down and the hold threshold has not elapsed. Cancelled by movement.
        case pending(at: CGPoint)
        /// The hold armed and the microphone is live.
        case listening(at: CGPoint, since: ContinuousClock.Instant)
    }

    public private(set) var phase: Phase = .idle

    public init() {}

    /// Where the ring is drawn, or nil when there is nothing to draw.
    public var touchPoint: CGPoint? {
        switch phase {
        case .idle: nil
        case .pending(let point): point
        case .listening(let point, _): point
        }
    }

    public var isListening: Bool {
        if case .listening = phase { return true }
        return false
    }

    /// The ring is only solid once the microphone is actually live, so the user can tell the difference between
    /// "I am pressing" and "it is hearing me" without looking away from their thumb.
    public var isArmed: Bool { isListening }

    /// A finger went down. Nothing is recorded yet.
    public mutating func touchBegan(at point: CGPoint) {
        phase = .pending(at: point)
    }

    /// The hold threshold elapsed with the finger still down. Returns whether the microphone should start.
    @discardableResult
    public mutating func holdElapsed(at instant: ContinuousClock.Instant) -> Bool {
        guard case .pending(let point) = phase else { return false }
        phase = .listening(at: point, since: instant)
        return true
    }

    /// The finger moved. A drag is a scroll or a text selection, never speech, so a pending hold is abandoned —
    /// but once the microphone is live the finger may wander freely, because the user is talking, not aiming.
    public mutating func touchMoved(to point: CGPoint, slop: CGFloat) {
        switch phase {
        case .pending(let origin):
            if hypot(point.x - origin.x, point.y - origin.y) > slop { phase = .idle }
        case .listening(_, let since):
            phase = .listening(at: point, since: since)
        case .idle:
            break
        }
    }

    /// What releasing the finger means.
    public enum Release: Sendable, Equatable {
        /// The hold never armed, so this was a tap or a scroll and belongs to whatever is under the finger.
        case nothingToDo
        /// Armed but released too fast to have said anything. Stop the microphone and keep the transcript.
        case discard
        /// A real utterance. Stop the microphone and keep what was heard.
        case commit
    }

    public mutating func touchEnded(at instant: ContinuousClock.Instant) -> Release {
        defer { phase = .idle }
        guard case .listening(_, let since) = phase else { return .nothingToDo }
        return instant - since >= Self.minimumUtterance ? .commit : .discard
    }

    /// The system took the touch away — a call arrived, the app went to the background. Never a commit: no one
    /// intended to finish speaking, so nothing is treated as said.
    public mutating func cancel() {
        phase = .idle
    }
}

/// How the touch ring is drawn.
///
/// The ring is the entire feedback channel for a gesture with no button: without it the user cannot tell whether
/// the hold registered, and would be talking into a screen that shows nothing.
public struct TouchRingPresentation: Sendable, Equatable {
    /// Diameter while the hold is still pending.
    public static let pendingDiameter: CGFloat = 44
    /// Diameter once the microphone is live. Larger, so arming is visible from the corner of an eye.
    public static let listeningDiameter: CGFloat = 84

    public let diameter: CGFloat
    public let isArmed: Bool
    public let center: CGPoint

    public init?(_ pushToTalk: PushToTalk) {
        guard let center = pushToTalk.touchPoint else { return nil }
        self.center = center
        self.isArmed = pushToTalk.isArmed
        self.diameter = pushToTalk.isArmed ? Self.listeningDiameter : Self.pendingDiameter
    }

    public var accessibilityLabel: String {
        isArmed ? "Listening. Release to finish." : "Hold to talk"
    }
}

extension Duration {
    /// Seconds as a `TimeInterval`, for the UIKit and SwiftUI gesture APIs.
    ///
    /// Thresholds are stated as `Duration` so they read in the units a person thinks in and can be compared
    /// against each other; the frameworks want a double.
    public var seconds: TimeInterval {
        let (whole, attoseconds) = components
        return TimeInterval(whole) + TimeInterval(attoseconds) / 1e18
    }
}
