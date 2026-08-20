import SwiftUI
import OpenPawProtocol

/// OpenPaw's visual system has exactly one idea, and every token below derives from it:
///
/// **Two registers.** A machine register — monospaced, square-cornered, cool-toned — carries everything the host
/// and the agent *did*: commands, output, diffs, event sequence numbers. A human register — serif, rounded,
/// warm-toned — carries everything that was *said*: the agent's prose, your prompts, empty-state direction. A
/// reader can tell at a glance whether they are looking at a fact or at a sentence.
///
/// **Risk is the accent.** The chrome is deliberately desaturated so that the risk ramp is the only saturated
/// colour on screen. When something is dangerous, it is the brightest thing in the frame. Colour is never the
/// only carrier: every risk surface also states its class in words and marks it with a glyph, because the
/// decision this app exists for must survive colour-blindness, sunlight and a cracked screen.
public enum OpenPawTheme {

    // MARK: - Ground and surfaces

    /// Cool slate ink. Not pure black: an OLED-black ground makes the risk ramp bloom and hides depth.
    public static let ink = Color(hex: 0x0E1116)
    /// Raised cool surface — the machine register.
    public static let panel = Color(hex: 0x161B22)
    /// Raised warm surface — the human register. The temperature shift is the whole point; do not unify them.
    public static let panelWarm = Color(hex: 0x1C1917)
    /// Recessed surface for code and terminal output.
    public static let well = Color(hex: 0x0A0D12)
    /// Hairlines and pane separators.
    public static let line = Color(hex: 0x2A313A)
    public static let lineStrong = Color(hex: 0x3A434E)

    public static let textPrimary = Color(hex: 0xE6EDF3)
    public static let textSecondary = Color(hex: 0x8B98A5)
    public static let textTertiary = Color(hex: 0x5A6672)

    public static let ok = Color(hex: 0x3FB950)
    public static let warn = Color(hex: 0xE3B341)
    public static let bad = Color(hex: 0xF04A4A)

    public static let diffAddedText = Color(hex: 0x56D364)
    public static let diffAddedFill = Color(hex: 0x2EA043).opacity(0.16)
    public static let diffRemovedText = Color(hex: 0xFF7B72)
    public static let diffRemovedFill = Color(hex: 0xF04A4A).opacity(0.14)
    public static let diffGutter = Color(hex: 0x3A434E)

    // MARK: - The risk ramp

    /// Hue *and* lightness both move across the ramp, so the order survives deuteranopia and greyscale.
    /// Credential access is magenta rather than a second red: "someone is reading your keys" and "someone is
    /// deleting your files" are different mistakes and must not look alike at a glance.
    public static func color(for risk: RiskClass) -> Color {
        switch risk {
        case .readOnly:            Color(hex: 0x4FB6C6)
        case .localWrite:          Color(hex: 0x7AA2F7)
        case .gitOperation:        Color(hex: 0xA78BFA)
        case .networkAccess:       Color(hex: 0xE3B341)
        case .packageInstallation: Color(hex: 0xE8873F)
        case .credentialAccess:    Color(hex: 0xF778BA)
        case .destructiveShell:    Color(hex: 0xF04A4A)
        case .unknown:             Color(hex: 0x8B98A5)
        }
    }

    /// SF Symbol carrying the same meaning as the colour, for anyone the colour does not reach.
    public static func glyph(for risk: RiskClass) -> String {
        switch risk {
        case .readOnly:            "eye"
        case .localWrite:          "square.and.pencil"
        case .gitOperation:        "arrow.triangle.branch"
        case .networkAccess:       "antenna.radiowaves.left.and.right"
        case .packageInstallation: "shippingbox"
        case .credentialAccess:    "key.fill"
        case .destructiveShell:    "flame.fill"
        case .unknown:             "questionmark.diamond"
        }
    }

    /// Short, lower-case, no marketing. The word a person would use out loud.
    public static func label(for risk: RiskClass) -> String {
        switch risk {
        case .readOnly:            "reads only"
        case .localWrite:          "writes files"
        case .gitOperation:        "changes git"
        case .networkAccess:       "uses network"
        case .packageInstallation: "installs packages"
        case .credentialAccess:    "touches credentials"
        case .destructiveShell:    "destructive"
        case .unknown:             "unclassified"
        }
    }

    public static func color(for category: InboxCategory) -> Color {
        switch category {
        case .permission:     Color(hex: 0xE8873F)
        case .question:       Color(hex: 0x7AA2F7)
        case .plan:           Color(hex: 0xA78BFA)
        case .toolFailure:    bad
        case .completion:     ok
        case .contextWarning: warn
        case .rateLimit:      warn
        case .backgroundJob:  textSecondary
        }
    }

    public static func glyph(for category: InboxCategory) -> String {
        switch category {
        case .permission:     "hand.raised.fill"
        case .question:       "questionmark.bubble.fill"
        case .plan:           "list.bullet.rectangle"
        case .toolFailure:    "xmark.octagon.fill"
        case .completion:     "checkmark.seal.fill"
        case .contextWarning: "gauge.with.dots.needle.67percent"
        case .rateLimit:      "hourglass"
        case .backgroundJob:  "clock.arrow.circlepath"
        }
    }

    // MARK: - Type

    /// Machine register. Monospaced everywhere, because column alignment is information.
    ///
    /// Every token is anchored to a `Font.TextStyle`, never a fixed point size. `Font.system(size:)` is frozen
    /// at that size for every reader — it ignores Dynamic Type entirely, including the accessibility sizes, and
    /// the defect is invisible in a screenshot taken at the default size. Anchoring to a text style keeps the
    /// scale ratios (headline > body, code > codeSmall) while letting the whole app grow. Five of the twelve
    /// tokens land on their previous point size at `.medium`, so the default appearance barely moves.
    public enum Machine {
        public static let display = Font.system(.title, design: .monospaced, weight: .semibold)
        public static let title = Font.system(.title3, design: .monospaced, weight: .semibold)
        public static let headline = Font.system(.callout, design: .monospaced, weight: .medium)
        public static let body = Font.system(.subheadline, design: .monospaced)
        public static let code = Font.system(.footnote, design: .monospaced)
        public static let codeSmall = Font.system(.caption2, design: .monospaced)
        /// The micro-label register: upper-case, tracked out, used for field names and section eyebrows.
        public static let label = Font.system(.caption2, design: .monospaced, weight: .semibold)
    }

    /// Human register. New York, because prose deserves a face that was designed for reading.
    public enum Human {
        public static let display = Font.system(.title, design: .serif, weight: .semibold)
        public static let title = Font.system(.title2, design: .serif, weight: .semibold)
        public static let prose = Font.system(.body, design: .serif)
        public static let proseTight = Font.system(.subheadline, design: .serif)
        public static let caption = Font.system(.footnote, design: .serif)
    }

    // MARK: - Metrics

    public enum Space {
        public static let hair: CGFloat = 2
        public static let tight: CGFloat = 4
        public static let small: CGFloat = 8
        public static let medium: CGFloat = 12
        public static let large: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
        public static let section: CGFloat = 48
    }

    public enum Radius {
        /// Machine surfaces are square. A terminal pane with rounded corners is a costume.
        public static let machine: CGFloat = 0
        public static let card: CGFloat = 6
        public static let sheet: CGFloat = 14
        public static let chip: CGFloat = 999
    }

    public static let hairline: CGFloat = 1 / 3
}

extension Color {
    /// 0xRRGGBB literal. Keeps the palette in one readable place instead of an asset catalog no reviewer opens.
    public init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

extension Text {
    /// The eyebrow/field-name treatment used throughout the machine register.
    public func microLabel(_ color: Color = OpenPawTheme.textTertiary) -> some View {
        self.font(OpenPawTheme.Machine.label)
            .tracking(0.9)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }
}
