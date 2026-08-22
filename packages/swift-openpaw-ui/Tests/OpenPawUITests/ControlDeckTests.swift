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
}
