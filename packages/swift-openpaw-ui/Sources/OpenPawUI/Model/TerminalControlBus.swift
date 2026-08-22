import Foundation

/// The wire between the strip's view page and the terminal screen.
///
/// These controls moved out of the terminal's own footer and onto the app-wide strip at the bottom, which means
/// the button and the state it acts on now live in different views. Search is a flag inside the terminal screen,
/// dictation owns a recognition task there, and copying reads that screen's scrollback: none of them can be
/// lifted out without dragging the terminal's internals up into the root.
///
/// So the strip publishes intent and the terminal screen subscribes. A screen that is not on top registers
/// nothing, so a tap on a terminal control from elsewhere does nothing rather than acting on a terminal the user
/// cannot see.
@MainActor
@Observable
public final class TerminalControlBus {
    /// Whether the terminal is listening right now.
    ///
    /// Reported back up because a microphone button that looks the same whether or not it is recording is the one
    /// state a user must never be unsure about.
    public private(set) var isDictating = false

    @ObservationIgnored public var onDictate: (() -> Void)?
    @ObservationIgnored public var onSearch: (() -> Void)?
    @ObservationIgnored public var onCopyAll: (() -> Void)?

    public init() {}

    public func dictate() { onDictate?() }
    public func search() { onSearch?() }
    public func copyAll() { onCopyAll?() }

    public func report(isDictating: Bool) {
        self.isDictating = isDictating
    }

    /// The button's glyph and what VoiceOver says about it.
    public var dictationGlyph: String { isDictating ? "mic.fill" : "mic" }
    public var dictationLabel: String { isDictating ? "Stop dictation" : "Dictate into a terminal draft" }

    /// Nothing on this screen is listening any more. Called when the terminal goes away, so the strip does not
    /// keep claiming a live microphone that was torn down with the screen.
    public func release() {
        onDictate = nil
        onSearch = nil
        onCopyAll = nil
        isDictating = false
    }
}
