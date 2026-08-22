import SwiftUI

/// The ring drawn under the user's finger while they hold to talk.
///
/// This is the whole feedback channel for a gesture with no button. Without it, holding the screen and speaking
/// is indistinguishable from holding the screen and nothing happening, so the ring has to say two things at a
/// glance: the touch registered, and the microphone is now open.
public struct TouchRing: View {
    private let presentation: TouchRingPresentation

    public init(_ presentation: TouchRingPresentation) {
        self.presentation = presentation
    }

    public var body: some View {
        ZStack {
            // The armed ring gets a soft halo so it reads as live from the corner of an eye, which is where it
            // will be: the user is looking at what they are dictating into, not at their thumb.
            if presentation.isArmed {
                Circle()
                    .fill(OpenPawTheme.signal.opacity(0.16))
                    .frame(width: presentation.diameter * 1.5, height: presentation.diameter * 1.5)
                    .blur(radius: 12)
            }
            Circle()
                .fill(presentation.isArmed ? OpenPawTheme.signal.opacity(0.18) : Color.clear)
            Circle()
                .strokeBorder(
                    presentation.isArmed ? OpenPawTheme.signal : OpenPawTheme.textTertiary,
                    lineWidth: presentation.isArmed ? 2.5 : 1.5
                )
        }
        .frame(width: presentation.diameter, height: presentation.diameter)
        .position(presentation.center)
        // The ring must never take a touch: the finger drawing it is still talking to whatever is underneath.
        .allowsHitTesting(false)
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: presentation.diameter)
        .accessibilityHidden(true)
    }
}
