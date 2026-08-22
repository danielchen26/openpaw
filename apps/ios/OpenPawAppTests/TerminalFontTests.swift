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

    /// Every private-use codepoint the user's own prompt printed, captured from a real login shell on the host.
    ///
    /// A powerlevel10k prompt is drawn almost entirely from Nerd Font icons in the private use area, and no font
    /// shipped on iOS contains a single one of them. Without a face that does, the terminal opens on a screen of
    /// tofu boxes — which is what "terminal 什么都看不到" actually was.
    private static let promptIcons: [(String, Character)] = [
        ("powerline right separator", "\u{E0B0}"), ("powerline left separator", "\u{E0B2}"),
        ("powerline right round", "\u{E0B4}"), ("powerline left round", "\u{E0B6}"),
        ("branch", "\u{E285}"), ("node", "\u{E617}"), ("apple", "\u{E711}"),
        ("folder opened", "\u{EA9C}"), ("terminal", "\u{EAB6}"), ("vm", "\u{EBA2}"),
        ("calendar", "\u{F073}"), ("folder", "\u{F07B}"), ("wifi", "\u{F120}"),
        ("database", "\u{F240}"), ("docker", "\u{F295}"), ("cloud", "\u{F308}"),
    ]

    /// The bug the user reported as the terminal showing nothing.
    ///
    /// The screen was not blank: it was their zsh prompt drawn entirely in tofu. These codepoints have no glyph in
    /// any system face, so CoreText has nothing to substitute and draws the missing-glyph box for every one.
    func testThePromptIconsTheHostPrintsHaveGlyphs() {
        let font = OpenPawTerminalView.terminalFont(ofSize: 13)

        for (name, icon) in Self.promptIcons {
            // Asserted through the same CoreText layout the terminal draws with, not just glyph availability:
            // a cascade that resolves for `CTFontCreateForString` can still be bypassed by the drawing path.
            XCTAssertEqual(
                renderedFace(of: String(icon), requesting: font), OpenPawTerminalView.symbolsFontName,
                "the \(name) icon (U+\(String(format: "%04X", icon.unicodeScalars.first!.value))) is drawn by "
                    + "another face, so the prompt is a row of tofu boxes"
            )
            XCTAssertTrue(
                hasGlyph(icon, in: font),
                "the \(name) icon (U+\(String(format: "%04X", icon.unicodeScalars.first!.value)) has no glyph, "
                    + "so the prompt draws it as a tofu box"
            )
        }
    }

    /// Bold is not decoration in a prompt: powerlevel10k emits it constantly, and `withSymbolicTraits` drops the
    /// cascade list, so a fallback attached only to the regular face would vanish exactly where the prompt is.
    func testPromptIconsSurviveEverySGRVariant() {
        for traits in [UIFontDescriptor.SymbolicTraits([]), .traitBold, .traitItalic, [.traitBold, .traitItalic]] {
            let font = OpenPawTerminalView.terminalFont(ofSize: 13, traits: traits)
            XCTAssertTrue(hasGlyph("\u{E0B0}", in: font), "the powerline separator is lost in \(traits)")
        }
    }

    /// Asks CoreText which face would actually draw this character, walking the cascade the way drawing does.
    ///
    /// The glyph id alone cannot answer this. When nothing on the device has the character, CoreText resolves to
    /// **LastResort**, a face that covers all of Unicode by design and returns a perfectly valid non-zero glyph —
    /// the box with a question mark in it. Asserting on the glyph id therefore passes while the user is looking at
    /// a screen of tofu, which is exactly what this test suite did at first.
    private func hasGlyph(_ character: Character, in font: UIFont) -> Bool {
        let text = String(character)
        let face = CTFontCreateForString(font, text as CFString,
                                         CFRange(location: 0, length: text.utf16.count))
        return (CTFontCopyPostScriptName(face) as String) != "LastResort"
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
