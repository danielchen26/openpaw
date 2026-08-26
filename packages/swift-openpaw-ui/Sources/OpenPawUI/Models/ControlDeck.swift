import CoreGraphics
import Foundation

/// The single strip of chrome at the bottom of the app, and what is on the page you swiped to.
///
/// It replaced three stacked rows. A screenshot from the phone showed a terminal control rail, a tab bar and the
/// key bar piled on top of each other, the last one crowded against the home indicator. Three rows is also three
/// separate answers to "where do I find things", which is why the bottom of the screen never looked settled.
///
/// One row now, paged sideways. The pages carry the same controls, grouped by what they are for, and the row
/// costs one row no matter how many pages exist. Adding a fourth group later costs nothing vertically, which is
/// the property the stacked arrangement did not have.
public struct ControlDeck: Sendable, Equatable {

    public enum Page: String, Sendable, CaseIterable, Identifiable {
        /// The keys a terminal needs and a software keyboard does not have: esc, ctrl, arrows, pipe, slash.
        case keys
        /// Where you are in the app. This page is the old tab bar.
        case destinations
        /// Adjustments to the terminal itself: dictation, scrollback search, copy, cell size.
        case view

        public var id: String { rawValue }

        /// Short, because the name sits under a strip of controls rather than over a screen.
        public var title: String {
            switch self {
            case .keys: "Keys"
            case .destinations: "Go"
            case .view: "View"
            }
        }

        public var glyph: String {
            switch self {
            case .keys: "keyboard"
            case .destinations: "square.grid.2x2"
            case .view: "textformat.size"
            }
        }
    }

    /// A control that can appear on a page of the strip.
    public enum Control: String, Sendable, CaseIterable {
        case dictate
        case search
        case copyAll
        case fontSmaller
        case fontLarger
    }

    /// Controls that stay visible whatever page you are on.
    ///
    /// Deliberately empty. The microphone button and the keyboard toggle both used to sit here permanently:
    /// holding anywhere now dictates and the keys have their own page, so each icon was spending permanent width
    /// on a job a gesture and a page already do.
    public static let alwaysVisibleControls: [Control] = []

    /// What sits on a given page. The keys page draws the shortcut set itself and the destinations page draws the
    /// app's destinations, so neither is a list of these controls.
    public static func controls(on page: Page) -> [Control] {
        switch page {
        case .keys, .destinations:
            []
        case .view:
            // Dictation keeps a button even though holding anywhere is the everyday route to it: a press held for
            // a third of a second is not a gesture a VoiceOver user can perform, and deleting the only button
            // would take speech away from the people who most need it.
            [.dictate, .search, .copyAll, .fontSmaller, .fontLarger]
        }
    }

    /// The always-visible handle: page dots that also fold the strip away.
    ///
    /// Short, because it is permanent. It is under Apple's 44-point minimum in height alone and earns that by
    /// spanning the full width of the screen, and by not being the only way to do its job — a downward swipe
    /// anywhere on the strip folds it too.
    public static let gripHeight: CGFloat = 20

    /// Room for one row of controls: a 44-point touch target plus the padding that keeps it off the terminal.
    ///
    /// 44 is Apple's floor for a reliable tap and is not negotiable downwards. A key cap you miss is worse than a
    /// key cap you cannot see, and this row carries the key caps.
    public static let contentHeight: CGFloat = 52

    public static let height: CGFloat = gripHeight + contentHeight

    /// Height when the strip is folded away, leaving the grip.
    ///
    /// Not zero: a strip that vanishes completely has no way back except a gesture nobody was told about, and a
    /// terminal with no visible controls is the state that gets reported as "the app lost its buttons".
    public static let collapsedHeight: CGFloat = gripHeight

    /// Height when the strip has been swiped off the side of the screen entirely.
    ///
    /// Zero, and the one arrangement where that is safe. Stowing is reached by swiping *past* the first page, so
    /// the user performed a deliberate horizontal gesture and knows the strip went sideways; the way back is the
    /// same gesture reversed. That is not true of folding, which can be arrived at by a stray vertical swipe.
    ///
    /// The handle it leaves behind is a tab against the leading edge rather than a full-width row, so the screen
    /// really is given over to content — which is the entire point of asking for it.
    public static let stowedHeight: CGFloat = 0

    /// The width of the tab left against the screen edge when the strip is stowed.
    ///
    /// Narrow, because it is permanently on screen over content. The visual remains 14 points wide while a separate
    /// 44-point hit region makes it reliable, and swiping right from that region unstows the strip too.
    public static let stowedHandleWidth: CGFloat = 14

    /// The visual edge tab stays narrow, but its interactive surface meets the platform touch-target minimum.
    public static let stowedHandleHitWidth: CGFloat = 44

    /// A rail of 52, a tab bar of 50 and a key bar of 48: what the three stacked rows cost, and the number the
    /// saving is measured against.
    public static let legacyHeight: CGFloat = 150

    public static func height(isCollapsed: Bool, isStowed: Bool = false) -> CGFloat {
        if isStowed { return stowedHeight }
        return isCollapsed ? collapsedHeight : height
    }

    public static func reclaimedHeight(isCollapsed: Bool, isStowed: Bool = false) -> CGFloat {
        legacyHeight - height(isCollapsed: isCollapsed, isStowed: isStowed)
    }

    /// The page order, left to right, with navigation in the middle so both other pages are one swipe away.
    public static let pages: [Page] = [.keys, .destinations, .view]

    public let page: Page
    public let isCollapsed: Bool
    /// Swiped off the leading edge of the screen, leaving content the whole screen.
    public let isStowed: Bool

    public init(page: Page = .destinations, isCollapsed: Bool = false, isStowed: Bool = false) {
        self.page = page
        self.isCollapsed = isCollapsed
        self.isStowed = isStowed
    }

    public var height: CGFloat { Self.height(isCollapsed: isCollapsed, isStowed: isStowed) }

    public var index: Int { Self.pages.firstIndex(of: page) ?? 0 }

    /// Whether a destination on the navigation page shows its name as well as its glyph.
    ///
    /// Six permanent text labels are six labels the user has already learned; the glyphs carry the meaning after
    /// the first day. Naming only the selection keeps the affordance for someone who has not learned them yet
    /// while giving the row back the height of a line of text.
    ///
    /// Accessibility sizes keep every label: someone who needs large text is not helped by inferring meaning from
    /// a glyph.
    public static func showsDestinationTitle(isSelected: Bool, isAccessibilitySize: Bool) -> Bool {
        isAccessibilitySize || isSelected
    }

    public static func previousDestination(before destination: ShellDestination) -> ShellDestination? {
        adjacentDestination(to: destination, offset: -1)
    }

    public static func nextDestination(after destination: ShellDestination) -> ShellDestination? {
        adjacentDestination(to: destination, offset: 1)
    }

    private static func adjacentDestination(
        to destination: ShellDestination,
        offset: Int
    ) -> ShellDestination? {
        guard let index = ShellDestination.allCases.firstIndex(of: destination) else { return nil }
        let adjacent = index + offset
        guard ShellDestination.allCases.indices.contains(adjacent) else { return nil }
        return ShellDestination.allCases[adjacent]
    }

    /// The page to show on arriving at a destination.
    ///
    /// A terminal is hard to drive from a phone without esc, ctrl and the arrows, so arriving there puts them
    /// under the thumb. Everywhere else the strip is the app's navigation and should say so.
    public static func page(arrivingAt destination: ShellDestination) -> Page {
        destination == .terminal ? .keys : .destinations
    }

    /// Paging runs off the leading end into stowing, and stops at the trailing end.
    ///
    /// Swiping back past the first page stows the strip off the side of the screen, which is where the request
    /// for a full screen is answered: the pages are already a horizontal series, so continuing that series one
    /// step further is the gesture the user is in the middle of rather than a new one to learn.
    ///
    /// The trailing end still stops dead. Wrapping there would mean a swipe left from the last page lands on the
    /// first, which reads as the gesture having gone the wrong way, and only one end can mean "away" before the
    /// direction stops carrying meaning.
    public func paged(_ direction: Direction) -> ControlDeck {
        if isStowed {
            // Any forward swipe brings it back, since there is nowhere further to go in that direction.
            return direction == .forward ? unstowed() : self
        }
        let next = index + (direction == .forward ? 1 : -1)
        guard Self.pages.indices.contains(next) else {
            return direction == .backward ? stowed() : self
        }
        return ControlDeck(page: Self.pages[next], isCollapsed: isCollapsed, isStowed: false)
    }

    public enum Direction: Sendable { case forward, backward }

    /// Off the side of the screen entirely.
    public func stowed() -> ControlDeck {
        ControlDeck(page: page, isCollapsed: isCollapsed, isStowed: true)
    }

    /// Back on screen, at the page it left from.
    ///
    /// Returning to the same page matters: the strip went sideways as one object, so bringing it back somewhere
    /// else would mean the gesture that reverses a movement does not reverse it.
    public func unstowed() -> ControlDeck {
        ControlDeck(page: page, isCollapsed: isCollapsed, isStowed: false)
    }

    public func collapsed(_ isCollapsed: Bool) -> ControlDeck {
        ControlDeck(page: page, isCollapsed: isCollapsed, isStowed: isStowed)
    }

    /// Showing a page implies the strip is on screen.
    ///
    /// Arriving at a screen whose controls live on the strip has to bring the strip back; leaving it stowed would
    /// mean navigating somewhere and finding the controls for it missing.
    public func showing(_ page: Page) -> ControlDeck {
        ControlDeck(page: page, isCollapsed: isCollapsed, isStowed: false)
    }

    /// Read out when the page changes, so paging is not a silent visual event.
    public var voiceLabel: String {
        if isStowed { return "Controls hidden" }
        return "\(page.title), page \(index + 1) of \(Self.pages.count)"
    }
}
