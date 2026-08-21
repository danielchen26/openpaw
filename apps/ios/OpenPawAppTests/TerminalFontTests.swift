import CoreText
import UIKit
import XCTest

@testable import OpenPawApp

/// The terminal's font has to be able to draw what the remote machine prints. `UIFont.monospacedSystemFont` — the
/// only face that gives a terminal its grid on iOS — contains no CJK glyphs at all, so a user reading Chinese
/// output is looking at whatever CoreText silently substituted, not at a face the app ever chose.
final class TerminalFontTests: XCTestCase {

    /// The face CoreText actually draws this string with, which is not necessarily the face that was asked for:
    /// when the requested font lacks a glyph, CoreText substitutes one per run.
    private func renderedFace(of text: String, requesting font: UIFont) -> String {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        guard let run = (CTLineGetGlyphRuns(line) as? [CTRun])?.first else { return "" }
        let attributes = CTRunGetAttributes(run) as NSDictionary
        guard let runFont = attributes[NSAttributedString.Key.font.rawValue as NSString] else { return "" }
        return CTFontCopyPostScriptName(runFont as! CTFont) as String
    }

    private func advance(_ text: String, in font: UIFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// The bug the user reported as "terminal 的 font 也不对".
    ///
    /// Without an explicit cascade the terminal renders Chinese in `.PingFangUITextSC`, a system *UI* face picked
    /// by CoreText — the same family iOS uses for buttons and labels, so Chinese output stops looking like
    /// terminal output at all. The fix names the text face, so the terminal draws Chinese in the font the app
    /// chose rather than in whatever the frameworks fell back to.
    func testCJKRendersInTheNamedFallbackFace() {
        let font = OpenPawTerminalView.terminalFont(ofSize: 13)

        for character in ["中", "文", "字", "语", "音"] {
            XCTAssertEqual(
                renderedFace(of: character, requesting: font), "PingFangSC-Regular",
                "'\(character)' is being drawn by a face the app never chose"
            )
        }
    }

    /// SwiftTerm derives bold and italic from the base descriptor with `withSymbolicTraits`, which resolves against
    /// a concrete family and **drops the cascade list**. So the terminal must set all four SGR faces itself; if it
    /// only sets the base font, Chinese reverts to CoreText's substitution the moment a program emits bold — which
    /// is most of them, since `ls`, shell prompts and every TUI use bold constantly.
    func testCJKFallbackSurvivesEverySGRVariant() {
        let variants: [(String, UIFontDescriptor.SymbolicTraits)] = [
            ("regular", []), ("bold", .traitBold), ("italic", .traitItalic),
            ("bold italic", [.traitBold, .traitItalic]),
        ]

        for (name, traits) in variants {
            let font = OpenPawTerminalView.terminalFont(ofSize: 13, traits: traits)
            XCTAssertEqual(
                renderedFace(of: "中", requesting: font), "PingFangSC-Regular",
                "the CJK fallback is lost in the \(name) variant, so Chinese changes face mid-screen"
            )
        }
    }

    /// A terminal is a fixed grid: SwiftTerm measures one cell from `"W"` and steps every column by that width. If
    /// the Latin glyphs are not all one width the text drifts away from the cursor. Adding the CJK fallback must
    /// not disturb this.
    func testLatinStaysMonospacedWithTheFallbackAttached() {
        for traits in [UIFontDescriptor.SymbolicTraits([]), .traitBold, .traitItalic] {
            let font = OpenPawTerminalView.terminalFont(ofSize: 13, traits: traits)
            let reference = advance("W", in: font)
            for character in ["i", "l", "m", "W", "0", "@"] {
                XCTAssertEqual(
                    advance(character, in: font), reference, accuracy: 0.01,
                    "'\(character)' is a different width from 'W', so the terminal grid cannot hold its columns"
                )
            }
        }
    }
}
