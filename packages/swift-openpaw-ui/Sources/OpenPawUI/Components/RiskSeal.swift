import OpenPawProtocol
import SwiftUI

/// The seal: a full-bleed band across the top of the approval sheet that is either closed or open.
///
/// This is the product's signature element, and it earns that by doing a job no label does. A request whose risk
/// demands the full command is *physically sealed*: the band is hatched, it says `SEALED`, and there is no approve
/// control anywhere on the sheet. Opening the detail consolidates the hatch into one solid field and the band says
/// `OPEN`. The gesture is not decoration — it is the only thing that puts an approve control on screen, so the
/// animation is reporting a state change in the safety model rather than entertaining anyone.
///
/// It is one of the app's intentionally sparse animations, and it honours `accessibilityReduceMotion` by switching
/// instantly instead of shortening the curve, because a 0.28 s cross-fade is still motion.
public struct RiskSeal: View {

    /// How long the hatch takes to consolidate. Long enough to read as one movement, short enough that a person
    /// tapping through a queue never waits for it.
    public static let consolidationDuration: Double = 0.28

    private let risk: Risk
    private let isAcknowledged: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(risk: Risk, isAcknowledged: Bool) {
        self.risk = risk
        self.isAcknowledged = isAcknowledged
    }

    private var tint: Color { OpenPawTheme.color(for: risk.riskClass) }
    private var word: String { OpenPawTheme.label(for: risk.riskClass) }

    public var body: some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
            header
            if !risk.reasons.isEmpty { reasons }
        }
        .padding(.horizontal, OpenPawTheme.Space.large)
        .padding(.vertical, OpenPawTheme.Space.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(tint.opacity(isAcknowledged ? 0.9 : 0.45))
                .frame(height: 2)
        }
        // Square. A seal with rounded corners is a sticker.
        .clipShape(Rectangle())
        .animation(reduceMotion ? nil : .easeOut(duration: Self.consolidationDuration), value: isAcknowledged)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: Layers

    /// Both states are always present and cross-faded by opacity, so nothing re-lays out mid-animation and the
    /// band cannot jump a pixel as it consolidates.
    private var fill: some View {
        ZStack {
            OpenPawTheme.panel
            Hatch(tint: tint)
                .opacity(isAcknowledged ? 0 : 1)
            tint.opacity(isAcknowledged ? 0.18 : 0)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: OpenPawTheme.Space.medium) {
            Image(systemName: OpenPawTheme.glyph(for: risk.riskClass))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
            Text(word)
                .font(OpenPawTheme.Machine.title)
                .foregroundStyle(OpenPawTheme.textPrimary)
            Spacer(minLength: OpenPawTheme.Space.small)
            state
        }
    }

    /// `SEALED` / `OPEN`, each with its own glyph. The word and the lock both change, so the state survives
    /// greyscale and the colour is never the only carrier.
    private var state: some View {
        HStack(spacing: OpenPawTheme.Space.tight) {
            Image(systemName: isAcknowledged ? "lock.open.fill" : "lock.fill")
                .font(.system(size: 10, weight: .bold))
            Text(isAcknowledged ? "open" : "sealed").microLabel(tint)
        }
        .foregroundStyle(tint)
    }

    private var reasons: some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
            Text("why").microLabel()
            ForEach(risk.reasons, id: \.self) { reason in
                HStack(alignment: .firstTextBaseline, spacing: OpenPawTheme.Space.small) {
                    Text("—")
                        .font(OpenPawTheme.Machine.codeSmall)
                        .foregroundStyle(OpenPawTheme.textTertiary)
                    Text(reason)
                        .font(OpenPawTheme.Machine.body)
                        .foregroundStyle(OpenPawTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var accessibilityText: String {
        var spoken = "risk: \(word). "
        spoken += isAcknowledged
            ? "Seal open, the full command has been shown."
            : "Sealed, the full command must be shown before this can be approved."
        if !risk.reasons.isEmpty {
            spoken += " Reasons: " + risk.reasons.joined(separator: ", ") + "."
        }
        return spoken
    }
}

// MARK: - The hatch

/// 45° hatching at a 6 pt pitch, drawn rather than tiled from an image so it stays crisp at every scale factor
/// and needs no asset.
struct Hatch: View {
    let tint: Color
    /// Horizontal distance between lines. The perpendicular spacing is this over root two.
    var pitch: CGFloat = 6

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            var path = Path()
            // Start far enough left that the leftmost visible line is complete.
            var offset: CGFloat = -size.height
            while offset <= size.width + size.height {
                path.move(to: CGPoint(x: offset, y: size.height))
                path.addLine(to: CGPoint(x: offset + size.height, y: 0))
                offset += pitch
            }
            context.stroke(path, with: .color(tint.opacity(0.35)), lineWidth: 1.5)
        }
        .drawingGroup()
        .accessibilityHidden(true)
    }
}

#Preview("Seal, both states") {
    VStack(spacing: OpenPawTheme.Space.xl) {
        RiskSeal(risk: PreviewFixtures.destructiveRisk, isAcknowledged: false)
        RiskSeal(risk: PreviewFixtures.destructiveRisk, isAcknowledged: true)
        RiskSeal(risk: PreviewFixtures.gitRisk, isAcknowledged: false)
    }
    .background(OpenPawTheme.ink)
}
