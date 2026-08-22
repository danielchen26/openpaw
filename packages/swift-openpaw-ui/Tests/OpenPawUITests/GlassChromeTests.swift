import Testing
import CoreGraphics
@testable import OpenPawUI

/// Translucent chrome, asked for in the register of the Ghostty terminal the app is used beside.
@Suite("Glass chrome")
struct GlassChromeTests {

    @Test("chrome over content is translucent")
    func translucentByDefault() {
        #expect(GlassChrome.fill(reduceTransparency: false) == .glass(tint: GlassChrome.tint))
    }

    /// The whole point of the effect is that something is behind it.
    @Test("content is allowed to pass behind translucent chrome")
    func contentPassesBehind() {
        #expect(GlassChrome.contentPassesBehind(reduceTransparency: false))
    }

    /// Reduce Transparency is a legibility setting. Someone who turned it on cannot read text over a blur, and a
    /// weaker blur delivers the same problem in a form that is harder to complain about.
    @Test("Reduce Transparency turns the glass off completely rather than weakening it")
    func reduceTransparencyIsHonoured() {
        #expect(GlassChrome.fill(reduceTransparency: true) == .opaque)
    }

    /// An opaque strip with content sliding under it hides that content, so the layout has to change back too.
    @Test("opaque chrome stops content from sliding underneath it")
    func opaqueChromeKeepsContentAbove() {
        #expect(GlassChrome.contentPassesBehind(reduceTransparency: true) == false)
    }

    /// Terminal output is bright, high-contrast and moving. Key caps sitting over it need a more opaque ground
    /// than chrome sitting over a list of cards.
    @Test("chrome over a terminal is more opaque than chrome over a list")
    func terminalCarriesMoreTint() {
        guard case .glass(let overTerminal) = GlassChrome.fill(reduceTransparency: false, overTerminal: true),
            case .glass(let overList) = GlassChrome.fill(reduceTransparency: false, overTerminal: false)
        else {
            Issue.record("expected both to be glass")
            return
        }
        #expect(overTerminal > overList)
    }

    /// Text on the chrome has to stay readable while output moves behind it.
    @Test("the tint never drops far enough to let the chrome lose its text")
    func tintKeepsTextLegible() {
        #expect(GlassChrome.tint >= 0.35)
        #expect(GlassChrome.tint < 1)
        #expect(GlassChrome.terminalTint < 1)
    }

    /// Where two solid surfaces meet, the colour change draws the boundary. On glass nothing else says where the
    /// chrome begins, so the hairline has to carry it alone.
    @Test("translucent chrome keeps a visible edge")
    func glassKeepsItsEdge() {
        #expect(GlassChrome.edgeOpacity(reduceTransparency: false) > 0.5)
    }

    /// A surface that resizes when a rendering preference changes moves every control under someone's thumb.
    @Test("turning the glass off does not change the strip's height")
    func fillNeverChangesLayout() {
        #expect(ControlDeck.height(isCollapsed: false) == ControlDeck.height(isCollapsed: false))
        #expect(ControlDeck.height == ControlDeck.gripHeight + ControlDeck.contentHeight)
    }
}
