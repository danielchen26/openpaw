import CoreGraphics
import Foundation

/// How much of the screen the app's own chrome is allowed to take at the bottom of a terminal.
///
/// On a phone the terminal had two full-width bars stacked under it — a control row and a tab bar — plus the
/// shortcut bar and the software keyboard. Measured on an iPhone 16 Pro that is 180 points of chrome under a
/// 602-point terminal: nearly a quarter of the screen spent on controls that are used a few times a session,
/// while the thing the user came for gets squeezed.
///
/// The fix is a single rail that carries the same controls in a collapsed form and expands on demand, so the
/// default state costs one row instead of two.
public enum CompactChrome {

    /// Height of the collapsed rail: one 44-point touch target plus the padding that separates it from the
    /// terminal. 44 is Apple's minimum for a reliable tap and is not negotiable downwards.
    public static let railHeight: CGFloat = 52

    /// Height of the expanded rail, which shows the same controls plus the ones that were folded away.
    public static let expandedRailHeight: CGFloat = 104

    /// What the old two-bar arrangement cost, kept as the number the saving is measured against.
    public static let legacyChromeHeight: CGFloat = 116

    public static func railHeight(isExpanded: Bool) -> CGFloat {
        isExpanded ? expandedRailHeight : railHeight
    }

    /// Height of the tab bar, which now names only the destination the user is on.
    ///
    /// Six permanent text labels are six labels the user has already learned; the icons carry the meaning after
    /// the first day. Naming only the selection keeps the affordance for someone who has not learned them while
    /// giving the row back the height of a line of text.
    public static func tabBarHeight(isAccessibilitySize: Bool) -> CGFloat {
        isAccessibilitySize ? 64 : 50
    }

    /// Accessibility sizes keep every label. Someone who needs large text is not helped by inference from a glyph,
    /// and at that size the row is tall enough to carry them anyway.
    public static func showsTabTitle(isSelected: Bool, isAccessibilitySize: Bool) -> Bool {
        isAccessibilitySize || isSelected
    }

    /// The rail must leave the terminal more room than the arrangement it replaces, in its default state.
    /// Expanded it may cost more, because the user asked for it and can collapse it again.
    public static func reclaimedHeight(isExpanded: Bool) -> CGFloat {
        legacyChromeHeight - railHeight(isExpanded: isExpanded)
    }
}

/// Which controls the terminal rail shows, and in which state.
///
/// Modelled rather than expressed directly in the view so the collapse rules can be tested without a simulator:
/// the reason the bars were too tall in the first place is that nothing described what they were allowed to cost.
public struct TerminalRailPresentation: Sendable, Equatable {

    public enum Control: String, Sendable, CaseIterable {
        case dictate
        case keys
        case search
        case copyAll
        case fontSmaller
        case fontSize
        case fontLarger
        case expand
    }

    public let isExpanded: Bool
    /// Controls on the single visible row. Collapsed, this is the short list; expanded, everything.
    public let controls: [Control]
    public let height: CGFloat

    public init(isExpanded: Bool) {
        self.isExpanded = isExpanded
        // Collapsed keeps dictation, the keyboard toggle and the disclosure. Font size, scrollback search and
        // copying are things a user reaches for occasionally, so they are what folds away; dictation is the one
        // control this app is built around, so it never does.
        //
        // Search and copy live here because the long press that used to raise them belongs to speech now.
        self.controls =
            isExpanded
            ? [.dictate, .keys, .search, .copyAll, .fontSmaller, .fontSize, .fontLarger, .expand]
            : [.dictate, .keys, .expand]
        self.height = CompactChrome.railHeight(isExpanded: isExpanded)
    }

    public var expandLabel: String {
        isExpanded ? "Hide terminal controls" : "Show more terminal controls"
    }

    public var expandGlyph: String {
        isExpanded ? "chevron.down" : "ellipsis"
    }
}
