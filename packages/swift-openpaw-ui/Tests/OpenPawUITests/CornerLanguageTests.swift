import CoreGraphics
import Testing

@testable import OpenPawUI

/// The corner language, tested because "more modern" is otherwise an opinion nobody can check.
///
/// The complaint that produced these was a screenshot of the home screen: a square-cornered hero card holding
/// square-cornered stat tiles, sitting directly above a rounded device card. Two corner languages on one screen
/// read as an unfinished app rather than as a deliberate distinction.
@Suite("Corner language")
struct CornerLanguageTests {

    @Test("machine surfaces are softened, not squared off")
    func machineSurfacesAreNoLongerSharp() {
        // Square corners were meant to mark machine output as machine output. On a phone, next to rounded cards,
        // they just look like a container someone forgot to style. The distinction survives as a *tighter* radius
        // rather than none: still visibly crisper than a card, no longer a different design language.
        #expect(OpenPawTheme.Radius.machine > 0)
        #expect(OpenPawTheme.Radius.machine < OpenPawTheme.Radius.card)
    }

    @Test("each step up the containment ladder is rounder than the one it holds")
    func radiiIncreaseWithContainment() {
        // A card inside a sheet has to read as nested. Equal radii make the inner element look like it is
        // fighting the outer one for the same corner.
        #expect(OpenPawTheme.Radius.machine < OpenPawTheme.Radius.card)
        #expect(OpenPawTheme.Radius.card < OpenPawTheme.Radius.sheet)
    }

    @Test("a nested radius stays concentric with the container that holds it")
    func nestedRadiusIsConcentric() {
        // Concentric corners: inner = outer - inset keeps the two curves parallel instead of pinching.
        #expect(OpenPawTheme.Radius.nested(in: 22, inset: 8) == 14)

        // Below the floor it stops shrinking. A 2-point radius on a card reads as a rendering error, not as a
        // tight corner, so the ladder has a bottom.
        #expect(OpenPawTheme.Radius.nested(in: 16, inset: 12) == OpenPawTheme.Radius.card)
    }

    @Test("the terminal itself keeps its edges")
    func theTerminalIsNotRounded() {
        // The one surface that genuinely must not be rounded: a PTY is a grid of cells, and rounding it clips
        // the corner cells of the grid the host is drawing into.
        #expect(OpenPawTheme.Radius.terminal == 0)
    }
}
