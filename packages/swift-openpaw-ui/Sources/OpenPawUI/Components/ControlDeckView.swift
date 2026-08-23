import SwiftUI

/// The single strip of controls at the bottom of the app, paged sideways.
///
/// One row where there used to be three: a terminal control rail, a tab bar and the key bar, stacked, with the
/// last of them crowded against the home indicator. Swiping the strip moves between groups of controls rather
/// than stacking those groups, so the row costs one row however many groups there are.
///
/// Page and fold gestures stay on the strip itself. Only the small handle left by an explicitly stowed strip accepts
/// a leading-edge restore swipe, so ordinary back navigation keeps ownership of the rest of the screen edge.
public struct ControlDeckView<KeysPage: View, DestinationsPage: View, ViewPage: View>: View {
    @Binding private var deck: ControlDeck
    private let overTerminal: Bool
    private let keys: KeysPage
    private let destinations: DestinationsPage
    private let view: ViewPage

    public init(
        deck: Binding<ControlDeck>,
        overTerminal: Bool = false,
        @ViewBuilder keys: () -> KeysPage,
        @ViewBuilder destinations: () -> DestinationsPage,
        @ViewBuilder view: () -> ViewPage
    ) {
        self._deck = deck
        self.overTerminal = overTerminal
        self.keys = keys()
        self.destinations = destinations()
        self.view = view()
    }

    public var body: some View {
        if deck.isStowed {
            edgeHandle
        } else {
            strip
        }
    }

    /// What is left when the strip has been swiped off the side: a tab against the leading edge.
    ///
    /// Deliberately not a full-width bar. A bar spanning the screen is the thing that was just dismissed, and
    /// leaving one behind would mean the gesture gave back none of the height it was asked for.
    private var edgeHandle: some View {
        HStack(spacing: 0) {
            Button {
                deck = deck.unstowed()
            } label: {
                Capsule()
                    .fill(OpenPawTheme.textTertiary)
                    .frame(width: 4, height: 36)
                    .frame(width: ControlDeck.stowedHandleWidth, height: 44)
                    .frame(
                        width: ControlDeck.stowedHandleHitWidth,
                        height: 44,
                        alignment: .leading
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show controls")
            .simultaneousGesture(edgeRestoreSwipe)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        // Over the content rather than beside it: a stowed strip that still reserved a row would not have given
        // the screen back, which is the whole of what was asked for.
        .background(Color.clear)
        .transition(.move(edge: .leading).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityAdjustableAction { direction in
            if direction == .increment { deck = deck.unstowed() }
        }
    }

    private var strip: some View {
        VStack(spacing: 0) {
            grip
            if !deck.isCollapsed {
                pages
                    .frame(height: ControlDeck.contentHeight)
                    .clipped()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(height: deck.height, alignment: .top)
        // Translucent, with the app's content running underneath rather than stopping above. The blur is only
        // half of it: what makes a surface read as glass is that something is genuinely moving behind it.
        .glassChrome(overTerminal: overTerminal, edge: .top)
        .contentShape(Rectangle())
        .transition(.move(edge: .leading))
        .animation(.snappy(duration: 0.24), value: deck)
        // Paging loses to anything inside the strip that wants the drag first, which is what keeps the key bar
        // scrollable sideways while the strip itself also pages sideways.
        .simultaneousGesture(swipe)
        .accessibilityElement(children: .contain)
        // VoiceOver cannot swipe a strip: the rotor's adjustable actions are how it pages instead.
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: deck = deck.paged(.forward)
            case .decrement: deck = deck.paged(.backward)
            @unknown default: break
            }
        }
    }

    /// The always-visible part: page dots that double as the handle for folding the strip away.
    ///
    /// The dots stay visible while folded, so the strip still says it exists and which page it will come back to,
    /// rather than leaving a terminal with no controls and no clue.
    private var grip: some View {
        Button {
            deck = deck.collapsed(!deck.isCollapsed)
        } label: {
            HStack(spacing: OpenPawTheme.Space.tight) {
                ForEach(Array(ControlDeck.pages.enumerated()), id: \.element.id) { index, page in
                    Capsule()
                        .fill(index == deck.index ? OpenPawTheme.textSecondary : OpenPawTheme.line)
                        .frame(width: index == deck.index ? 16 : 6, height: 3)
                        .accessibilityHidden(true)
                        .id(page.id)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: ControlDeck.gripHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(deck.isCollapsed ? "Show controls" : "Hide controls")
        .accessibilityValue(deck.voiceLabel)
    }

    /// All three pages, laid side by side and slid into view.
    ///
    /// Kept in one row rather than swapped by a `switch` so paging animates as movement: the page you left goes
    /// out the side the swipe went, which is what tells the user the pages sit next to each other.
    @ViewBuilder
    private var pages: some View {
        switch deck.page {
        case .keys: keys
        case .destinations: destinations
        case .view: view
        }
    }

    /// Horizontal drags page; a vertical drag folds the strip away and back.
    ///
    /// The distance is deliberately short. This is a 52-point row, so a swipe across it is a flick of a thumb
    /// rather than a drag, and asking for long travel would make it feel stuck.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 16)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height
                if abs(horizontal) > abs(vertical) {
                    deck = deck.paged(horizontal < 0 ? .forward : .backward)
                } else {
                    deck = deck.collapsed(vertical > 0)
                }
            }
    }

    /// A dedicated leading-edge swipe makes restoration reliable without turning the whole stowed screen into a
    /// gesture target. The same 44-point region remains directly tappable and accessible.
    private var edgeRestoreSwipe: some Gesture {
        DragGesture(minimumDistance: 12)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height
                if horizontal >= 24, horizontal > abs(vertical) {
                    deck = deck.unstowed()
                }
            }
    }
}
