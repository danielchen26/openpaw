#if os(iOS)

    import SwiftUI
    import UIKit

    /// Hold anywhere on the screen to talk.
    ///
    /// The recognizer is installed on the **window**, not on an overlay view, for the same reason the two-finger
    /// tap is: an overlay that accepted touches would swallow scrolling, typing and every button in the app, and a
    /// view whose `hitTest` returns nil never receives the touches its own recognizer needs. On the window a
    /// recognizer with `cancelsTouchesInView = false` observes every touch without consuming any of them, so the
    /// terminal still scrolls and buttons still work while the hold is being measured.
    ///
    /// Nothing about the touch is interpreted here. The recognizer reports began/moved/ended and ``PushToTalk``
    /// decides what they mean, because that decision has edge cases worth testing and a `UIGestureRecognizer`
    /// cannot be exercised without a simulator.
    public struct PushToTalkCatcher: UIViewRepresentable {

        /// Points a finger may drift before a pending hold is treated as a scroll.
        static let slop: CGFloat = PushToTalk.slop

        let onBegan: (CGPoint) -> Void
        let onArmed: () -> Void
        let onMoved: (CGPoint) -> Void
        let onEnded: () -> Void
        let onCancelled: () -> Void

        public init(
            onBegan: @escaping (CGPoint) -> Void,
            onArmed: @escaping () -> Void,
            onMoved: @escaping (CGPoint) -> Void,
            onEnded: @escaping () -> Void,
            onCancelled: @escaping () -> Void
        ) {
            self.onBegan = onBegan
            self.onArmed = onArmed
            self.onMoved = onMoved
            self.onEnded = onEnded
            self.onCancelled = onCancelled
        }

        public func makeUIView(context: Context) -> UIView {
            let view = WindowHost()
            view.isUserInteractionEnabled = false
            view.coordinator = context.coordinator
            return view
        }

        public func updateUIView(_ uiView: UIView, context: Context) {
            context.coordinator.apply(self)
        }

        public func makeCoordinator() -> Coordinator {
            Coordinator(self)
        }

        public static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
            coordinator.detach()
        }

        public final class Coordinator: NSObject, UIGestureRecognizerDelegate {
            private var catcher: PushToTalkCatcher
            private var recognizer: HoldRecognizer?
            private weak var installedOn: UIWindow?

            init(_ catcher: PushToTalkCatcher) {
                self.catcher = catcher
            }

            func apply(_ catcher: PushToTalkCatcher) {
                self.catcher = catcher
            }

            func attach(to window: UIWindow) {
                guard installedOn !== window else { return }
                detach()
                let hold = HoldRecognizer(target: self, action: #selector(fire))
                hold.cancelsTouchesInView = false
                hold.delaysTouchesBegan = false
                hold.delaysTouchesEnded = false
                hold.delegate = self
                window.addGestureRecognizer(hold)
                recognizer = hold
                installedOn = window
            }

            func detach() {
                if let recognizer, let installedOn {
                    installedOn.removeGestureRecognizer(recognizer)
                }
                recognizer = nil
                installedOn = nil
            }

            @objc private func fire(_ recognizer: HoldRecognizer) {
                switch recognizer.state {
                case .began: catcher.onArmed()
                case .changed: catcher.onMoved(recognizer.currentPoint)
                case .ended: catcher.onEnded()
                case .cancelled, .failed: catcher.onCancelled()
                default: break
                }
            }

            /// Every other recognizer in the app must keep working while a hold is being measured, including the
            /// terminal's own scrolling and text selection.
            public func gestureRecognizer(
                _ gestureRecognizer: UIGestureRecognizer,
                shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
            ) -> Bool {
                true
            }

            func touchDown(at point: CGPoint) { catcher.onBegan(point) }
            func touchDrifted(to point: CGPoint) { catcher.onMoved(point) }
            func touchUpBeforeArming() { catcher.onCancelled() }
        }

        /// A long press that reports the raw touch down as well as the armed state.
        ///
        /// `UILongPressGestureRecognizer` only enters `.began` once the press has already succeeded, which is far
        /// too late to draw the ring: the user would press, see nothing for a third of a second, and let go.
        /// Overriding `touchesBegan` is how the pending state becomes visible immediately.
        final class HoldRecognizer: UILongPressGestureRecognizer {
            private(set) var currentPoint: CGPoint = .zero
            private var didReportDown = false

            override init(target: Any?, action: Selector?) {
                super.init(target: target, action: action)
                minimumPressDuration = PushToTalk.holdThreshold.seconds
                allowableMovement = PushToTalkCatcher.slop
                numberOfTouchesRequired = 1
            }

            private var host: Coordinator? { delegate as? Coordinator }

            override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
                super.touchesBegan(touches, with: event)
                guard let touch = touches.first, let window = touch.window else { return }
                currentPoint = touch.location(in: window)
                didReportDown = true
                host?.touchDown(at: currentPoint)
            }

            override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
                super.touchesMoved(touches, with: event)
                guard let touch = touches.first, let window = touch.window else { return }
                currentPoint = touch.location(in: window)
                // Reported directly rather than only from `.changed`, because a drift that never armed still has
                // to retract the pending ring rather than leave it stranded on screen.
                host?.touchDrifted(to: currentPoint)
            }

            override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
                let wasArmed = state == .began || state == .changed
                super.touchesEnded(touches, with: event)
                // A lift before the press succeeded produces no state change at all, so the pending ring would
                // stay on screen forever without this.
                if didReportDown, !wasArmed { host?.touchUpBeforeArming() }
                didReportDown = false
            }

            override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
                super.touchesCancelled(touches, with: event)
                if didReportDown { host?.touchUpBeforeArming() }
                didReportDown = false
            }
        }

        private final class WindowHost: UIView {
            weak var coordinator: Coordinator?

            override func didMoveToWindow() {
                super.didMoveToWindow()
                if let window {
                    coordinator?.attach(to: window)
                } else {
                    coordinator?.detach()
                }
            }
        }
    }

#endif
