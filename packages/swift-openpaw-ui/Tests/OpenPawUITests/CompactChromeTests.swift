import CoreGraphics
import Testing

@testable import OpenPawUI

/// The user's complaint, in numbers: the bottom of a terminal screen was two full-width bars stacked on each
/// other, and on a phone that is a quarter of the screen spent on controls used a few times a session.
@Suite("Compact chrome")
struct CompactChromeTests {

    @Test("the collapsed rail gives the terminal back more than half the chrome it replaced")
    func collapsedRailReclaimsHeight() {
        #expect(CompactChrome.railHeight(isExpanded: false) == 52)
        // Two bars at 52 and 64 were 116 points. The collapsed rail must be a real saving, not a rearrangement.
        #expect(CompactChrome.reclaimedHeight(isExpanded: false) == 64)
        #expect(CompactChrome.railHeight(isExpanded: false) < CompactChrome.legacyChromeHeight / 2)
    }

    @Test("expanding costs height, which is why it is not the default")
    func expandingCostsHeight() {
        #expect(CompactChrome.railHeight(isExpanded: true) > CompactChrome.railHeight(isExpanded: false))
        // Even expanded it must not cost more than the arrangement it replaced, or expanding would be a regression.
        #expect(CompactChrome.railHeight(isExpanded: true) <= CompactChrome.legacyChromeHeight)
    }

    @Test("the collapsed rail keeps a 44 point touch target")
    func collapsedRailFitsATouchTarget() {
        // Below 44 points a control is unreliable to tap. Compactness must not be bought with missed taps.
        #expect(CompactChrome.railHeight(isExpanded: false) >= 44)
    }

    @Test("dictation and the keyboard survive collapsing, adjustments fold away")
    func collapsedRailKeepsWhatIsUsedConstantly() {
        let collapsed = TerminalRailPresentation(isExpanded: false)

        // Dictation is what this app is for: a phone keyboard is the reason to talk to a machine instead.
        #expect(collapsed.controls.contains(.dictate))
        #expect(collapsed.controls.contains(.keys))
        #expect(collapsed.controls.contains(.expand))
        // Font size and scrollback search are occasional, so they are what folds.
        #expect(!collapsed.controls.contains(.fontSize))
        #expect(!collapsed.controls.contains(.search))
    }

    @Test("copying the scrollback survives losing the long press")
    func copyAllIsReachableWithoutALongPress() {
        // The terminal's only route to select/copy used to be a long press, which now belongs to dictation.
        // Taking a gesture away is only allowed if what it reached is still reachable, so those actions moved
        // onto the rail. Collapsed they stay folded: reading and talking are the common case, copying is not.
        let expanded = TerminalRailPresentation(isExpanded: true)
        #expect(expanded.controls.contains(.copyAll))
        #expect(expanded.controls.contains(.search))

        let collapsed = TerminalRailPresentation(isExpanded: false)
        #expect(!collapsed.controls.contains(.copyAll))

        // Whatever else folds away, the control this app is built around does not.
        #expect(collapsed.controls.contains(.dictate))
    }

    @Test("expanding reveals every control, so nothing is lost by collapsing")
    func expandingRevealsEverything() {
        let expanded = TerminalRailPresentation(isExpanded: true)

        for control in TerminalRailPresentation.Control.allCases {
            #expect(expanded.controls.contains(control), "\(control) is unreachable in either state")
        }
    }

    @Test("the disclosure says which way it goes")
    func disclosureDescribesItsDirection() {
        #expect(TerminalRailPresentation(isExpanded: false).expandLabel == "Show more terminal controls")
        #expect(TerminalRailPresentation(isExpanded: true).expandLabel == "Hide terminal controls")
        #expect(TerminalRailPresentation(isExpanded: false).expandGlyph != TerminalRailPresentation(
            isExpanded: true).expandGlyph)
    }

    @Test("the tab bar names only where the user is, and gets shorter for it")
    func tabBarNamesOnlyTheSelection() {
        #expect(CompactChrome.tabBarHeight(isAccessibilitySize: false) == 50)
        // It has to actually be shorter than the row it replaces, or nothing was gained.
        #expect(CompactChrome.tabBarHeight(isAccessibilitySize: false)
            < RootNavigationLayout.compactTabBarHeight(isAccessibilitySize: false))

        #expect(CompactChrome.showsTabTitle(isSelected: true, isAccessibilitySize: false))
        #expect(!CompactChrome.showsTabTitle(isSelected: false, isAccessibilitySize: false))
    }

    @Test("accessibility sizes keep every label and the height to hold them")
    func accessibilitySizesKeepEveryLabel() {
        // Inferring a destination from a glyph is exactly what someone using large text should not have to do.
        #expect(CompactChrome.showsTabTitle(isSelected: false, isAccessibilitySize: true))
        #expect(CompactChrome.tabBarHeight(isAccessibilitySize: true)
            > CompactChrome.tabBarHeight(isAccessibilitySize: false))
    }

    @Test("the rail reports the height it is drawn at")
    func railReportsItsHeight() {
        for expanded in [true, false] {
            #expect(TerminalRailPresentation(isExpanded: expanded).height
                == CompactChrome.railHeight(isExpanded: expanded))
        }
    }
}
