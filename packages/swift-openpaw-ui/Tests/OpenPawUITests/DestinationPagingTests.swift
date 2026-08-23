import CoreGraphics
import Testing

@testable import OpenPawUI

@Suite("Root destination paging")
struct DestinationPagingTests {
    @Test("destinations are ordered for one-step paging")
    func destinationsHaveAStablePagingOrder() {
        #expect(ShellDestination.allCases == [.home, .terminal, .sessions, .inbox, .repo, .settings])
        #expect(DestinationPagingPolicy.destination(after: .next, from: .home) == .terminal)
        #expect(DestinationPagingPolicy.destination(after: .next, from: .terminal) == .sessions)
        #expect(DestinationPagingPolicy.destination(after: .previous, from: .repo) == .inbox)
    }

    @Test("legacy chat state migrates to Sessions")
    func legacyChatStateMigrates() {
        #expect(ShellDestination(rawValue: "chat") == .sessions)
        #expect(ShellDestination(rawValue: "sessions") == .sessions)
        #expect(ShellDestination(rawValue: "unknown") == nil)
    }

    @Test("one deliberate swipe moves exactly one destination")
    func aDeliberateSwipeMovesOnePage() {
        let next = DestinationPagingGesture(
            translationX: -80,
            translationY: 8,
            velocityX: -700,
            startX: 160
        )
        let previous = DestinationPagingGesture(
            translationX: 80,
            translationY: 8,
            velocityX: 700,
            startX: 160
        )

        #expect(DestinationPagingPolicy.decision(from: .terminal, gesture: next) == .next)
        #expect(DestinationPagingPolicy.destination(after: .next, from: .terminal) == .sessions)
        #expect(DestinationPagingPolicy.decision(from: .repo, gesture: previous) == .previous)
        #expect(DestinationPagingPolicy.destination(after: .previous, from: .repo) == .inbox)
    }

    @Test("distance, velocity, and horizontal dominance are all required")
    func thresholdsRejectAccidentalMovement() {
        #expect(
            DestinationPagingPolicy.decision(
                from: .terminal,
                gesture: DestinationPagingGesture(
                    translationX: -20, translationY: 2, velocityX: -700, startX: 160
                )
            ) == .ignore(.insufficientDistance)
        )
        #expect(
            DestinationPagingPolicy.decision(
                from: .terminal,
                gesture: DestinationPagingGesture(
                    translationX: -80, translationY: 2, velocityX: -120, startX: 160
                )
            ) == .ignore(.insufficientVelocity)
        )
        #expect(
            DestinationPagingPolicy.decision(
                from: .terminal,
                gesture: DestinationPagingGesture(
                    translationX: -80, translationY: 72, velocityX: -700, startX: 160
                )
            ) == .ignore(.verticalDominance)
        )
    }

    @Test("navigation and interactive child surfaces suppress root paging")
    func exclusionsStayLocal() {
        let leadingBack = DestinationPagingGesture(
            translationX: 80,
            translationY: 4,
            velocityX: 700,
            startX: 8,
            isBackNavigationAvailable: true
        )
        #expect(DestinationPagingPolicy.decision(from: .sessions, gesture: leadingBack) == .ignore(.leadingEdgeBack))

        let exclusions: [(DestinationPagingGesture, DestinationPageSuppression)] = [
            (
                deliberateNext(isModalPresented: true),
                .activeModal
            ),
            (
                deliberateNext(isHorizontalChildControlActive: true),
                .activeHorizontalChildControl
            ),
            (
                deliberateNext(isTextSelectionActive: true),
                .textSelection
            ),
            (
                deliberateNext(isInboxRowActionActive: true),
                .inboxRowAction
            ),
        ]

        for (gesture, suppression) in exclusions {
            #expect(DestinationPagingPolicy.decision(from: .sessions, gesture: gesture) == .ignore(suppression))
        }
    }

    @Test("paging never wraps at either end")
    func pagingIsBounded() {
        #expect(
            DestinationPagingPolicy.decision(
                from: .home,
                gesture: DestinationPagingGesture(
                    translationX: 80, translationY: 2, velocityX: 700, startX: 160
                )
            ) == .ignore(.boundary)
        )
        #expect(DestinationPagingPolicy.decision(from: .settings, gesture: deliberateNext()) == .ignore(.boundary))
        #expect(DestinationPagingPolicy.destination(after: .previous, from: .home) == .home)
        #expect(DestinationPagingPolicy.destination(after: .next, from: .settings) == .settings)
    }

    private func deliberateNext(
        isModalPresented: Bool = false,
        isHorizontalChildControlActive: Bool = false,
        isTextSelectionActive: Bool = false,
        isInboxRowActionActive: Bool = false
    ) -> DestinationPagingGesture {
        DestinationPagingGesture(
            translationX: -80,
            translationY: 4,
            velocityX: -700,
            startX: 160,
            isModalPresented: isModalPresented,
            isHorizontalChildControlActive: isHorizontalChildControlActive,
            isTextSelectionActive: isTextSelectionActive,
            isInboxRowActionActive: isInboxRowActionActive
        )
    }
}
