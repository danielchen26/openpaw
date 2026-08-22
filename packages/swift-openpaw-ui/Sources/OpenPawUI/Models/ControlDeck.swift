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

    /// A rail of 52, a tab bar of 50 and a key bar of 48: what the three stacked rows cost, and the number the
    /// saving is measured against.
    public static let legacyHeight: CGFloat = 150

    public static func height(isCollapsed: Bool) -> CGFloat {
        isCollapsed ? collapsedHeight : height
    }

    public static func reclaimedHeight(isCollapsed: Bool) -> CGFloat {
        legacyHeight - height(isCollapsed: isCollapsed)
    }

    /// The page order, left to right, with navigation in the middle so both other pages are one swipe away.
    public static let pages: [Page] = [.keys, .destinations, .view]

    public let page: Page
    public let isCollapsed: Bool

    public init(page: Page = .destinations, isCollapsed: Bool = false) {
        self.page = page
        self.isCollapsed = isCollapsed
    }

    public var height: CGFloat { Self.height(isCollapsed: isCollapsed) }

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

    /// The page to show on arriving at a destination.
    ///
    /// A terminal is hard to drive from a phone without esc, ctrl and the arrows, so arriving there puts them
    /// under the thumb. Everywhere else the strip is the app's navigation and should say so.
    public static func page(arrivingAt destination: ShellDestination) -> Page {
        destination == .terminal ? .keys : .destinations
    }

    /// Paging is bounded rather than wrapping.
    ///
    /// A wrapping strip means a swipe left from the first page lands on the last, which reads as the gesture
    /// having gone the wrong way. Stopping at the ends also gives the swipe a floor and a ceiling to feel.
    public func paged(_ direction: Direction) -> ControlDeck {
        let next = index + (direction == .forward ? 1 : -1)
        guard Self.pages.indices.contains(next) else { return self }
        return ControlDeck(page: Self.pages[next], isCollapsed: isCollapsed)
    }

    public enum Direction: Sendable { case forward, backward }

    public func collapsed(_ isCollapsed: Bool) -> ControlDeck {
        ControlDeck(page: page, isCollapsed: isCollapsed)
    }

    public func showing(_ page: Page) -> ControlDeck {
        ControlDeck(page: page, isCollapsed: isCollapsed)
    }

    /// Read out when the page changes, so paging is not a silent visual event.
    public var voiceLabel: String {
        "\(page.title), page \(index + 1) of \(Self.pages.count)"
    }
}
