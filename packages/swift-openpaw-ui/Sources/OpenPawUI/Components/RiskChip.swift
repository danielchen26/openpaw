import OpenPawProtocol
import SwiftUI

/// A risk class, stated three ways at once: colour, glyph, and the word itself.
///
/// The redundancy is the point. This chip is the label on every command the agent wants to run, and the decision
/// it informs has to survive colour-blindness, direct sunlight and a cracked screen — so the colour is never
/// carrying the meaning alone. All three come from `OpenPawTheme`, which is the only source of risk appearance.
public struct RiskChip: View {

    /// Three sizes, for three jobs: beside a command in a transcript, on a list row, and at the head of a sheet.
    public enum Style: Sendable, Hashable {
        /// Inside a line of text. Quiet enough not to interrupt reading.
        case inline
        /// On a list row. Upper-cased and tracked, so it scans in a column.
        case badge
        /// At the top of a decision surface. The loudest thing on the screen, on purpose.
        case hero
    }

    private let risk: Risk
    private let style: Style

    public init(risk: Risk, style: Style = .inline) {
        self.risk = risk
        self.style = style
    }

    private var tint: Color { OpenPawTheme.color(for: risk.riskClass) }
    private var word: String { OpenPawTheme.label(for: risk.riskClass) }
    private var glyph: String { OpenPawTheme.glyph(for: risk.riskClass) }

    public var body: some View {
        HStack(spacing: glyphSpacing) {
            Image(systemName: glyph)
                .font(.system(size: glyphSize, weight: .semibold))
            label
        }
        .foregroundStyle(tint)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background(tint.opacity(0.14), in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(tint.opacity(0.55), lineWidth: OpenPawTheme.hairline * 2)
        )
        .clipShape(Capsule(style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var label: some View {
        switch style {
        case .inline:
            Text(word).font(OpenPawTheme.Machine.codeSmall)
        case .badge:
            Text(word).microLabel(tint)
        case .hero:
            Text(word).font(OpenPawTheme.Machine.headline)
        }
    }

    /// Reads the class first, then why. VoiceOver users get the verdict before the evidence, same as sighted ones.
    private var accessibilityText: String {
        var spoken = "risk: \(word)"
        if !risk.reasons.isEmpty {
            spoken += ", reasons: " + risk.reasons.joined(separator: ", ")
        }
        if risk.requiresDetailExpansion {
            spoken += ", full command must be opened before approving"
        }
        return spoken
    }

    // MARK: Metrics

    private var glyphSize: CGFloat {
        switch style {
        case .inline: 9
        case .badge: 10
        case .hero: 14
        }
    }

    private var glyphSpacing: CGFloat {
        switch style {
        case .inline, .badge: OpenPawTheme.Space.tight
        case .hero: OpenPawTheme.Space.small
        }
    }

    private var horizontalPadding: CGFloat {
        switch style {
        case .inline: OpenPawTheme.Space.small
        case .badge: OpenPawTheme.Space.medium
        case .hero: OpenPawTheme.Space.large
        }
    }

    private var verticalPadding: CGFloat {
        switch style {
        case .inline: OpenPawTheme.Space.hair
        case .badge: OpenPawTheme.Space.tight
        case .hero: OpenPawTheme.Space.small
        }
    }
}

#Preview("Risk chips") {
    VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
        ForEach(RiskClass.allCases, id: \.self) { riskClass in
            HStack(spacing: OpenPawTheme.Space.medium) {
                RiskChip(
                    risk: Risk(riskClass: riskClass, requiresDetailExpansion: false, reasons: []),
                    style: .inline
                )
                RiskChip(
                    risk: Risk(riskClass: riskClass, requiresDetailExpansion: false, reasons: []),
                    style: .badge
                )
            }
        }
        RiskChip(risk: PreviewFixtures.destructiveRisk, style: .hero)
    }
    .padding(OpenPawTheme.Space.xl)
    .background(OpenPawTheme.ink)
}
