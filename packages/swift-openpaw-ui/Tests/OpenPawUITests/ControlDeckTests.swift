import CoreGraphics
import Testing

@testable import OpenPawUI

/// The bottom strip, tested because its whole reason for existing is a height budget.
@Suite("Control deck")
struct ControlDeckTests {

    @Test("one paged row costs far less than the three rows it replaced")
    func theStripIsCheaperThanTheStack() {
        // A rail, a tab bar and a key bar came to 150 points before the home indicator's inset, which is what the
        // reported screenshot showed piled up at the bottom of the screen.
        #expect(ControlDeck.height < ControlDeck.legacyHeight / 2)
        // Over half the old chrome handed back to the terminal, and nearly all of it when folded.
        #expect(ControlDeck.reclaimedHeight(isCollapsed: false) > 70)
        #expect(ControlDeck.reclaimedHeight(isCollapsed: true) > 125)
    }

    @Test("a fourth page would cost nothing in height")
    func pagesAreFreeVertically() {
        // The property the stack did not have: grouping controls sideways means the row is the same height no
        // matter how many groups exist.
        let heights = Set(ControlDeck.pages.map { ControlDeck(page: $0).height })
        #expect(heights.count == 1)
        #expect(heights.first == ControlDeck.height)
    }

    @Test("the strip keeps a 44 point touch target")
    func theStripCanBeTapped() {
        // Apple's floor for a reliable tap. Below it the controls are visible but not usable, which is worse than
        // not showing them.
        #expect(ControlDeck.contentHeight >= 44)
    }

    @Test("collapsing leaves a way back")
    func collapsingIsNotDisappearing() {
        let collapsed = ControlDeck(page: .keys, isCollapsed: true)
        #expect(collapsed.height == ControlDeck.collapsedHeight)
        #expect(collapsed.height < ControlDeck.height)
        // Never zero. A strip that vanishes entirely leaves the user with a terminal and no controls, and a
        // gesture nobody told them about as the only way back.
        #expect(collapsed.height > 0)
    }

    @Test("the page you land on follows the screen you are on")
    func theTerminalLandsOnKeys() {
        // A phone keyboard has no esc, no ctrl and no arrows, so a terminal is hard to drive without this page.
        #expect(ControlDeck.page(arrivingAt: .terminal) == .keys)
        // Everywhere else the strip is the app's navigation and should say so rather than showing terminal keys
        // over a settings screen.
        for destination in ShellDestination.allCases where destination != .terminal {
            #expect(ControlDeck.page(arrivingAt: destination) == .destinations)
        }
    }

    @Test("navigation sits between the other two pages")
    func navigationIsOneSwipeFromAnywhere() {
        // Whichever page you are on, the way to another screen is a single swipe.
        #expect(ControlDeck.pages[1] == .destinations)
    }

    @Test("paging moves one page at a time and stops at the ends")
    func pagingIsBounded() {
        let first = ControlDeck(page: .keys)
        #expect(first.paged(.forward).page == .destinations)
        #expect(first.paged(.forward).paged(.forward).page == .view)

        // Bounded rather than wrapping: a swipe left from the first page landing on the last reads as the gesture
        // having gone the wrong way.
        #expect(first.paged(.backward).page == .keys)
        let last = ControlDeck(page: ControlDeck.pages.last!)
        #expect(last.paged(.forward).page == last.page)
    }

    @Test("paging keeps the collapsed state it was in")
    func pagingDoesNotReopenACollapsedStrip() {
        // Swiping a folded strip must not unfold it. The user folded it to see more terminal.
        let collapsed = ControlDeck(page: .keys, isCollapsed: true)
        #expect(collapsed.paged(.forward).isCollapsed)
    }

    @Test("dictation leaves the strip but not the app")
    func dictationStaysReachableWithoutAnIcon() {
        // Holding anywhere replaced the microphone button, so the icon was taking permanent space for a gesture
        // that already works. It cannot simply be deleted: a long press held for a second is not a gesture a
        // VoiceOver user can perform, so removing the only button would remove their only route to speech.
        #expect(!ControlDeck.alwaysVisibleControls.contains(.dictate))
        #expect(ControlDeck.controls(on: .view).contains(.dictate))
    }

    @Test("nothing is permanent except the handle")
    func noControlHoldsPermanentWidth() {
        // The microphone and the keyboard toggle both used to sit on every screen. Each was spending permanent
        // width on a job a gesture and a page now do.
        #expect(ControlDeck.alwaysVisibleControls.isEmpty)
    }

    @Test("every page says which one it is, in view and out loud")
    func pagesAreNamed() {
        for page in ControlDeck.pages {
            #expect(!page.title.isEmpty)
            #expect(!page.glyph.isEmpty)
        }
        // Paging is otherwise a silent visual event for someone using VoiceOver.
        #expect(ControlDeck(page: .destinations).voiceLabel == "Go, page 2 of 3")
    }

    @Test("compact navigation exposes only the current destination and its neighbours")
    func compactNavigationIsSinglePurpose() {
        #expect(ControlDeck.previousDestination(before: .home) == nil)
        #expect(ControlDeck.nextDestination(after: .home) == .terminal)
        #expect(ControlDeck.previousDestination(before: .inbox) == .sessions)
        #expect(ControlDeck.nextDestination(after: .inbox) == .repo)
        #expect(ControlDeck.previousDestination(before: .settings) == .repo)
        #expect(ControlDeck.nextDestination(after: .settings) == nil)
    }
}

/// Swiping the strip off the side of the screen entirely.
///
/// Asked for directly: fold it all the way to the left and the screen behind it becomes full screen. The strip is
/// already a horizontal series of pages, so one more step in the direction the user is already swiping costs no
/// new gesture to learn.
@Suite("Control deck stowing")
struct ControlDeckStowingTests {

    @Test("swiping back past the first page stows the strip off the screen")
    func swipingPastTheFirstPageStows() {
        let deck = ControlDeck(page: .keys)
        #expect(deck.paged(.backward).isStowed)
    }

    /// The whole request: what is left is the screen.
    @Test("a stowed strip takes no height at all")
    func stowedTakesNoHeight() {
        #expect(ControlDeck(page: .keys, isStowed: true).height == 0)
    }

    /// A gesture that reverses a movement has to reverse it.
    @Test("swiping forward brings the strip back to the page it left from")
    func unstowingReturnsToTheSamePage() {
        let stowed = ControlDeck(page: .keys).paged(.backward)
        let back = stowed.paged(.forward)
        #expect(back.isStowed == false)
        #expect(back.page == .keys)
    }

    /// Only one end can mean "away" before the direction stops carrying meaning.
    @Test("the far end still stops rather than stowing or wrapping")
    func trailingEndStops() {
        let last = ControlDeck(page: .view)
        #expect(last.paged(.forward) == last)
    }

    /// Swiping again while stowed must not do something new.
    @Test("a stowed strip stays stowed when swiped further in the same direction")
    func stowedStaysStowed() {
        let stowed = ControlDeck(page: .keys, isStowed: true)
        #expect(stowed.paged(.backward) == stowed)
    }

    /// Navigating somewhere and finding its controls missing would be a defect.
    @Test("arriving at a screen brings a stowed strip back")
    func navigationUnstows() {
        let stowed = ControlDeck(page: .keys, isStowed: true)
        #expect(stowed.showing(.destinations).isStowed == false)
    }

    /// Stowed is not a state VoiceOver can see, so it has to be a state VoiceOver is told.
    @Test("a stowed strip says so rather than reading out a page it is not showing")
    func stowedSpeaksItsState() {
        #expect(ControlDeck(page: .keys, isStowed: true).voiceLabel == "Controls hidden")
    }

    /// A tab against the edge, not a full-width bar: a bar would be the thing that was just dismissed.
    @Test("what is left behind is a narrow edge handle rather than a row")
    func handleIsNarrow() {
        #expect(ControlDeck.stowedHandleWidth < 44)
        #expect(ControlDeck.stowedHandleWidth > 0)
        #expect(ControlDeck.stowedHandleHitWidth >= 44)
        #expect(ControlDeck.stowedHandleHitWidth > ControlDeck.stowedHandleWidth)
    }

    /// Folding and stowing are different states and must not be confused for each other.
    @Test("folding leaves the grip and stowing does not")
    func foldingAndStowingDiffer() {
        #expect(ControlDeck(isCollapsed: true).height == ControlDeck.gripHeight)
        #expect(ControlDeck(isStowed: true).height == 0)
    }
}
