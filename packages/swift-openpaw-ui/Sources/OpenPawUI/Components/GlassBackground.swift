import SwiftUI

/// Paints chrome as translucent glass over whatever is behind it.
///
/// The blur is the cheap half. The half that matters is that the layout lets content run underneath the chrome:
/// a material drawn over a flat fill is a flat fill that costs more to render. Callers that use this are expected
/// to let their content extend behind the chrome rather than stopping above it.
///
/// The tint is the app's own surface colour laid back over the material at partial strength. Platform materials
/// are neutral grey, and neutral grey over a palette this cool reads as a system control pasted onto the app.
public struct GlassBackground: ViewModifier {
    /// Reduce Transparency exists because blurred backgrounds make text hard to read for some people. It is
    /// honoured by turning the effect off rather than softening it.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private let overTerminal: Bool
    private let edge: Edge?

    public init(overTerminal: Bool = false, edge: Edge? = nil) {
        self.overTerminal = overTerminal
        self.edge = edge
    }

    public func body(content: Content) -> some View {
        content
            .background {
                fill
                    // The chrome sits inside the safe area but the band beyond it — the home indicator, the
                    // status bar — is still screen. Without this the fill stops at the safe area while the
                    // content sliding under the chrome does not, so that content reappears in the gap below it.
                    .ignoresSafeArea(edges: extendedEdge)
            }
            .overlay(alignment: edgeAlignment) {
                if edge != nil {
                    Rectangle()
                        .fill(
                            OpenPawTheme.line
                                .opacity(GlassChrome.edgeOpacity(reduceTransparency: reduceTransparency))
                        )
                        .frame(height: OpenPawTheme.hairline)
                }
            }
    }

    @ViewBuilder
    private var fill: some View {
        switch GlassChrome.fill(reduceTransparency: reduceTransparency, overTerminal: overTerminal) {
        case .glass(let tint):
            // Material first, app colour over it. The other order tints nothing, because the material would be
            // blurring the tint rather than the content behind the whole stack.
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(OpenPawTheme.panel.opacity(tint))
        case .opaque:
            Rectangle().fill(OpenPawTheme.panel)
        }
    }

    /// Chrome extends away from the content it faces.
    ///
    /// The hairline is on the side facing the content, so the screen edge is the other side — a strip at the
    /// bottom of the screen carries its line on top and has to reach down past the home indicator.
    private var extendedEdge: SwiftUI.Edge.Set {
        edge == .top ? .bottom : .top
    }

    private var edgeAlignment: Alignment {
        edge == .top ? .top : .bottom
    }
}

extension View {
    /// Chrome that floats over content rather than sitting beside it.
    ///
    /// - Parameters:
    ///   - overTerminal: Terminal output is bright, high-contrast and moving, so chrome over it carries more
    ///     tint than chrome over a list of cards.
    ///   - edge: Which side gets the separating hairline. On glass this line is the only thing saying where the
    ///     chrome begins, so it is not optional decoration wherever the chrome meets content.
    public func glassChrome(overTerminal: Bool = false, edge: Edge? = nil) -> some View {
        modifier(GlassBackground(overTerminal: overTerminal, edge: edge))
    }
}
