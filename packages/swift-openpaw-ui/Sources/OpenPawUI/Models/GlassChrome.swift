import CoreGraphics
import Foundation

/// How chrome that floats over content is filled.
///
/// Asked for by name: the terminal this app is used next to is Ghostty, whose window is translucent, and the
/// request was for the same register here. What makes that read as glass is not the blur on its own — it is that
/// something is genuinely behind it. Chrome painted with a material over a flat fill is a flat fill with extra
/// cost, so the layout has to let content pass behind the chrome before any of this is worth drawing.
///
/// Glass is paint and never layout. The strip reserves the same height whichever fill it uses, because a surface
/// that changes size when a rendering preference changes moves every control under someone's thumb.
public struct GlassChrome: Sendable, Equatable {

    public enum Fill: Sendable, Equatable {
        /// A blurred material, tinted back toward the app's cool grey.
        ///
        /// The tint is not decoration. Platform materials are neutral, and neutral grey over a palette this cool
        /// reads as a foreign control pasted onto the app, which is the exact complaint that "make it look like
        /// Ghostty" is about.
        case glass(tint: Double)
        /// A solid fill, for anyone who asked the system not to show translucency.
        case opaque
    }

    /// How much of the app's own surface colour is laid back over the material.
    ///
    /// High enough that text on the chrome keeps its contrast when bright output passes behind it, low enough
    /// that the movement behind the glass is still visible. Below about a third the key caps start to fight
    /// whatever is underneath them, which is a legibility bug rather than a taste one.
    public static let tint: Double = 0.55

    /// Chrome over the terminal carries more tint than chrome over a list.
    ///
    /// Terminal output is high-contrast text on a dark ground, and it moves. Letting that through at list
    /// strength puts moving glyphs directly under a row of key caps, so the surface the keys sit on has to be
    /// more opaque than one sitting over a scrolling card list.
    public static let terminalTint: Double = 0.72

    /// Reduce Transparency is a legibility setting, not a taste one, so it is honoured exactly.
    ///
    /// Someone who turned it on did so because blurred backgrounds make text hard to read. Approximating with a
    /// weaker blur would deliver the problem they were avoiding in a form that is harder to complain about.
    public static func fill(reduceTransparency: Bool, overTerminal: Bool = false) -> Fill {
        guard !reduceTransparency else { return .opaque }
        return .glass(tint: overTerminal ? terminalTint : tint)
    }

    /// Whether content is allowed to draw underneath the chrome.
    ///
    /// False when the fill is opaque: sliding content beneath a surface it cannot be seen through only hides it.
    public static func contentPassesBehind(reduceTransparency: Bool) -> Bool {
        !reduceTransparency
    }

    /// The separating hairline's strength.
    ///
    /// A translucent edge needs a firmer line than an opaque one. Where two solid surfaces meet, the colour
    /// change draws the boundary by itself; on glass the boundary is the only thing saying where the chrome
    /// starts, and without it the strip's controls look like they are floating in the output behind them.
    public static func edgeOpacity(reduceTransparency: Bool) -> Double {
        reduceTransparency ? 1.0 : 0.85
    }
}
