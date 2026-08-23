#if os(iOS)

    import SwiftUI
    import UIKit

    /// A child surface that owns a horizontal interaction the root pager must not steal.
    public enum DestinationSwipeExclusion: String, Sendable, Hashable {
        case horizontalChildControl
        case textSelection
        case inboxRowAction
    }

    /// Installs one non-cancelling pan recognizer on the window and turns a completed fling into a root-page intent.
    ///
    /// The recognizer observes rather than competes: touches keep flowing to the terminal, lists, text input, and
    /// nested scroll views. Child surfaces place frame markers where horizontal interaction is local. This bridge
    /// reads those markers at the gesture's starting point, consults ``DestinationPagingPolicy``, and reports only a
    /// previous/next intent. `RootView` remains the sole owner of navigation state.
    public struct DestinationSwipeCatcher: UIViewRepresentable {
        private var destination: ShellDestination
        private var isBackNavigationAvailable: Bool
        private var isModalPresented: Bool
        private var onIntent: (DestinationPageDecision) -> Void

        public init(
            destination: ShellDestination,
            isBackNavigationAvailable: Bool,
            isModalPresented: Bool,
            onIntent: @escaping (DestinationPageDecision) -> Void
        ) {
            self.destination = destination
            self.isBackNavigationAvailable = isBackNavigationAvailable
            self.isModalPresented = isModalPresented
            self.onIntent = onIntent
        }

        public func makeUIView(context: Context) -> WindowHost {
            let view = WindowHost()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = true
            view.coordinator = context.coordinator
            context.coordinator.host = view
            context.coordinator.apply(self)
            return view
        }

        public func updateUIView(_ uiView: WindowHost, context: Context) {
            context.coordinator.apply(self)
            uiView.reclaimKeyboardFocusIfAvailable()
        }

        public func makeCoordinator() -> Coordinator {
            Coordinator(self)
        }

        public static func dismantleUIView(_ uiView: WindowHost, coordinator: Coordinator) {
            coordinator.detach()
        }

        @MainActor
        public final class Coordinator: NSObject, UIGestureRecognizerDelegate {
            private var catcher: DestinationSwipeCatcher
            private var recognizer: TrackingPanRecognizer?
            private weak var installedOn: UIWindow?
            fileprivate weak var host: WindowHost?
            private var activeExclusions: Set<DestinationSwipeExclusion> = []
            private var activeTextSelection = false

            init(_ catcher: DestinationSwipeCatcher) {
                self.catcher = catcher
            }

            func apply(_ catcher: DestinationSwipeCatcher) {
                self.catcher = catcher
                host?.accessibilityValue = catcher.destination.title
                host?.accessibilityCustomActions = [
                    UIAccessibilityCustomAction(
                        name: "Previous Tab", target: self,
                        selector: #selector(previousAccessibilityAction)
                    ),
                    UIAccessibilityCustomAction(
                        name: "Next Tab", target: self,
                        selector: #selector(nextAccessibilityAction)
                    ),
                ]
            }

            func attach(to window: UIWindow) {
                guard installedOn !== window else { return }
                detach()
                let pan = TrackingPanRecognizer(target: self, action: #selector(fire))
                pan.cancelsTouchesInView = false
                pan.delaysTouchesBegan = false
                pan.delaysTouchesEnded = false
                pan.delegate = self
                window.addGestureRecognizer(pan)
                recognizer = pan
                installedOn = window
            }

            func detach() {
                if let recognizer, let installedOn {
                    installedOn.removeGestureRecognizer(recognizer)
                }
                recognizer = nil
                installedOn = nil
            }

            @objc private func fire(_ recognizer: TrackingPanRecognizer) {
                guard let window = installedOn else { return }
                switch recognizer.state {
                case .began:
                    // Child controls can move while their gesture is active. A List row slides left to reveal its
                    // actions, for example, so asking where its marker is only after the drag ends loses the fact that
                    // the touch began inside that row. Ownership is decided at touch-down and retained for the turn.
                    activeExclusions = exclusionKinds(at: recognizer.startPoint, in: window)
                    activeTextSelection = hasActiveTextSelection(startingAt: recognizer.initialView)
                    recognizer.record(velocityX: recognizer.velocity(in: window).x)
                    return
                case .changed:
                    recognizer.record(velocityX: recognizer.velocity(in: window).x)
                    return
                case .ended:
                    recognizer.record(velocityX: recognizer.velocity(in: window).x)
                default:
                    activeExclusions = []
                    activeTextSelection = false
                    return
                }
                let translation = recognizer.translation(in: window)
                let exclusions = activeExclusions
                let textSelectionIsActive = activeTextSelection
                activeExclusions = []
                activeTextSelection = false
                let backAvailable = catcher.isBackNavigationAvailable || navigationControllerCanGoBack(in: window)
                let gesture = DestinationPagingGesture(
                    translationX: translation.x,
                    translationY: translation.y,
                    // UIKit often reports nearly zero after the finger has lifted. Keeping the strongest velocity
                    // observed while the recognizer was changing preserves the fling the user actually made.
                    velocityX: recognizer.peakVelocityX,
                    startX: recognizer.startPoint.x,
                    isBackNavigationAvailable: backAvailable,
                    isModalPresented: catcher.isModalPresented || modalPresentationIsActive(in: window),
                    isHorizontalChildControlActive: exclusions.contains(.horizontalChildControl),
                    // Selection is UIKit state, not a layout affordance. Capture it at touch-down, before a selection
                    // drag can move or collapse the range, and retain that ownership through the completed gesture.
                    isTextSelectionActive: textSelectionIsActive,
                    isInboxRowActionActive: exclusions.contains(.inboxRowAction)
                )
                let decision = DestinationPagingPolicy.decision(from: catcher.destination, gesture: gesture)
                switch decision {
                case .previous, .next:
                    catcher.onIntent(decision)
                case .ignore:
                    break
                }
            }

            /// A modal or a navigation animation owns the window until it settles. A leading-edge back pan is left to
            /// the NavigationStack's own recognizer before this recognizer ever enters `.began`.
            public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
                guard let pan = gestureRecognizer as? TrackingPanRecognizer, let window = installedOn else { return false }
                guard !catcher.isModalPresented, !modalPresentationIsActive(in: window) else {
                    return false
                }
                guard !navigationTransitionIsActive(in: window) else {
                    return false
                }
                let velocity = pan.velocity(in: window)
                let backAvailable = catcher.isBackNavigationAvailable || navigationControllerCanGoBack(in: window)
                if backAvailable, pan.startPoint.x <= DestinationPagingPolicy.leadingEdgeWidth, velocity.x > 0 {
                    return false
                }
                return true
            }

            public func gestureRecognizer(
                _ gestureRecognizer: UIGestureRecognizer,
                shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
            ) -> Bool {
                true
            }

            @objc private func previousAccessibilityAction() -> Bool {
                request(.previous)
            }

            @objc private func nextAccessibilityAction() -> Bool {
                request(.next)
            }

            fileprivate func performAccessibilityIncrement() {
                _ = request(.next)
            }

            fileprivate func performAccessibilityDecrement() {
                _ = request(.previous)
            }

            @discardableResult
            private func request(_ decision: DestinationPageDecision) -> Bool {
                let destination = DestinationPagingPolicy.destination(after: decision, from: catcher.destination)
                guard destination != catcher.destination else { return false }
                catcher.onIntent(decision)
                return true
            }

            private func exclusionKinds(at point: CGPoint, in window: UIWindow) -> Set<DestinationSwipeExclusion> {
                var result: Set<DestinationSwipeExclusion> = []
                collectMarkers(in: window, point: point, result: &result)
                return result
            }

            private func collectMarkers(
                in view: UIView,
                point: CGPoint,
                result: inout Set<DestinationSwipeExclusion>
            ) {
                if let marker = view as? ExclusionMarkerView,
                   !marker.isHidden,
                   marker.alpha > 0.01,
                   marker.window != nil,
                   marker.convert(marker.bounds, to: installedOn).contains(point) {
                    result.insert(marker.kind)
                }
                for child in view.subviews {
                    collectMarkers(in: child, point: point, result: &result)
                }
            }

            private func hasActiveTextSelection(startingAt view: UIView?) -> Bool {
                var candidate = view
                while let current = candidate {
                    if let input = current as? any UITextInput {
                        if input.markedTextRange != nil { return true }
                        if let range = input.selectedTextRange,
                           input.offset(from: range.start, to: range.end) != 0 {
                            return true
                        }
                    }
                    candidate = current.superview
                }
                return false
            }

            private func navigationControllerCanGoBack(in window: UIWindow) -> Bool {
                navigationControllers(in: window.rootViewController).contains { $0.viewControllers.count > 1 }
            }

            private func navigationTransitionIsActive(in window: UIWindow) -> Bool {
                navigationControllers(in: window.rootViewController).contains { $0.transitionCoordinator != nil }
            }

            /// Child destinations own their own sheets and alerts, so `RootView` cannot describe every modal through
            /// its local state. UIKit still exposes those presentations from the window's controller tree. Refusing to
            /// begin while any visible controller is presented keeps a root fling from dismissing or paging underneath
            /// Add Device, Inbox recovery, repository import, and future destination-owned flows.
            private func modalPresentationIsActive(in window: UIWindow) -> Bool {
                hasActivePresentation(in: window.rootViewController)
            }

            private func hasActivePresentation(in controller: UIViewController?) -> Bool {
                guard let controller else { return false }
                // UIKit keeps `presentedViewController` attached through the dismissal transition. Treat that whole
                // interval as modal ownership, including the frames after `isBeingDismissed` becomes true, so the root
                // recognizer cannot begin underneath an animating sheet.
                if controller.presentedViewController != nil {
                    return true
                }
                return controller.children.contains { hasActivePresentation(in: $0) }
            }

            private func navigationControllers(in controller: UIViewController?) -> [UINavigationController] {
                guard let controller else { return [] }
                var result: [UINavigationController] = []
                if let navigation = controller as? UINavigationController { result.append(navigation) }
                for child in controller.children {
                    result.append(contentsOf: navigationControllers(in: child))
                }
                if let presented = controller.presentedViewController {
                    result.append(contentsOf: navigationControllers(in: presented))
                }
                return result
            }
        }

        public final class WindowHost: UIView {
            weak var coordinator: Coordinator?

            public override var canBecomeFirstResponder: Bool { true }

            override init(frame: CGRect) {
                super.init(frame: frame)
                isUserInteractionEnabled = true
                isAccessibilityElement = true
                accessibilityIdentifier = "root.destination.pager"
                accessibilityLabel = "Root tabs"
                accessibilityTraits = [.adjustable]
            }

            required init?(coder: NSCoder) {
                fatalError("init(coder:) has not been implemented")
            }

            public override func didMoveToWindow() {
                super.didMoveToWindow()
                if let window {
                    coordinator?.attach(to: window)
                    reclaimKeyboardFocusIfAvailable()
                } else {
                    coordinator?.detach()
                }
            }

            fileprivate func reclaimKeyboardFocusIfAvailable() {
                DispatchQueue.main.async { [weak self] in
                    guard let self, let window = self.window else { return }
                    let responder = window.openpawFirstResponder
                    guard responder == nil || responder === self else { return }
                    let claimed = self.becomeFirstResponder()
                    self.accessibilityHint = claimed ? "Keyboard shortcuts active" : "Keyboard shortcuts inactive"
                }
            }

            public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
                var handled = false
                for press in presses {
                    guard let key = press.key else { continue }
                    let keyKind: DestinationKeyboardKey = switch key.charactersIgnoringModifiers {
                    case UIKeyCommand.inputLeftArrow: .leftArrow
                    case UIKeyCommand.inputRightArrow: .rightArrow
                    default: .other
                    }
                    let uiModifiers = key.modifierFlags.union(event?.modifierFlags ?? [])
                    var modifiers = DestinationSwipeCatcher.keyboardModifiers(from: uiModifiers)
                    #if DEBUG && targetEnvironment(simulator)
                        // XCUITest 26.5 emits the requested arrow but drops modifier flags from both UIKey and
                        // UIPressesEvent. This opt-in fixture restores only the chord the test explicitly requested;
                        // release builds and ordinary simulator launches still use the real event flags above.
                        if modifiers.isEmpty,
                           ProcessInfo.processInfo.arguments.contains("-openpaw-ui-test-command-option-arrows") {
                            modifiers = [.command, .option]
                        }
                    #endif
                    switch DestinationKeyboardShortcutPolicy.decision(key: keyKind, modifiers: modifiers) {
                    case .previous:
                        coordinator?.performAccessibilityDecrement()
                        handled = true
                    case .next:
                        coordinator?.performAccessibilityIncrement()
                        handled = true
                    case .ignore, nil:
                        break
                    }
                }
                if !handled { super.pressesBegan(presses, with: event) }
            }

            public override func accessibilityIncrement() {
                coordinator?.performAccessibilityIncrement()
            }

            public override func accessibilityDecrement() {
                coordinator?.performAccessibilityDecrement()
            }
        }

        private final class TrackingPanRecognizer: UIPanGestureRecognizer {
            private(set) var startPoint: CGPoint = .zero
            private(set) weak var initialView: UIView?
            private(set) var peakVelocityX: CGFloat = 0

            func record(velocityX: CGFloat) {
                if abs(velocityX) > abs(peakVelocityX) { peakVelocityX = velocityX }
            }

            override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
                peakVelocityX = 0
                if let touch = touches.first, let window = touch.window {
                    startPoint = touch.location(in: window)
                    initialView = touch.view
                }
                super.touchesBegan(touches, with: event)
            }
        }

        /// Converts the four semantic modifiers relevant to root paging without discarding extras. Keeping Shift and
        /// Control in the typed set is what makes Command-Option an exact chord rather than a permissive subset.
        static func keyboardModifiers(from flags: UIKeyModifierFlags) -> DestinationKeyboardModifiers {
            var modifiers: DestinationKeyboardModifiers = []
            if flags.contains(.command) { modifiers.insert(.command) }
            if flags.contains(.alternate) { modifiers.insert(.option) }
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.control) { modifiers.insert(.control) }
            return modifiers
        }
    }

    private extension UIView {
        var openpawFirstResponder: UIView? {
            if isFirstResponder { return self }
            for child in subviews {
                if let responder = child.openpawFirstResponder { return responder }
            }
            return nil
        }
    }

    private struct DestinationSwipeExclusionMarker: UIViewRepresentable {
        let kind: DestinationSwipeExclusion

        func makeUIView(context: Context) -> ExclusionMarkerView {
            let marker = ExclusionMarkerView()
            marker.kind = kind
            marker.isUserInteractionEnabled = false
            marker.isAccessibilityElement = false
            marker.backgroundColor = .clear
            return marker
        }

        func updateUIView(_ uiView: ExclusionMarkerView, context: Context) {
            uiView.kind = kind
        }
    }

    private final class ExclusionMarkerView: UIView {
        var kind: DestinationSwipeExclusion = .horizontalChildControl
    }

    public extension View {
        /// Marks the receiver's frame as a child-owned horizontal interaction for the window-level root pager.
        func destinationSwipeExclusion(_ kind: DestinationSwipeExclusion) -> some View {
            background(DestinationSwipeExclusionMarker(kind: kind).allowsHitTesting(false))
        }
    }

#else

    import SwiftUI

    public enum DestinationSwipeExclusion: String, Sendable, Hashable {
        case horizontalChildControl
        case textSelection
        case inboxRowAction
    }

    public extension View {
        func destinationSwipeExclusion(_ kind: DestinationSwipeExclusion) -> some View { self }
    }

#endif
