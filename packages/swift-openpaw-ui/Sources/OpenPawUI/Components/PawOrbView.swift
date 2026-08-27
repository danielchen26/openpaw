import SwiftUI

public enum PawOrbPresentation {
    public static let visualDiameter = RadialLauncherLayout.orbVisualDiameter
    public static let hitDiameter = RadialLauncherLayout.orbHitDiameter
}

public enum RadialNodePresentation {
    public static let visualDiameter = RadialLauncherLayout.nodeVisualDiameter
    public static let hitDiameter = RadialLauncherLayout.nodeHitDiameter

    /// Rendered node centers for the sibling ring at `depth`, delegating both the quadrant math and the ring
    /// radius to the same `RadialGeometry` that maps drag points to selections. Rendering and selection can
    /// therefore never disagree.
    public nonisolated static func positions(
        count: Int,
        origin: CGPoint,
        depth: Int = 1,
        geometry: RadialGeometry = RadialGeometry()
    ) -> [CGPoint] {
        let radius = geometry.ringRadius(depth: depth)
        return (0..<max(0, count)).map {
            geometry.nodePosition(index: $0, count: count, origin: origin, radius: radius)
        }
    }
}

public enum LauncherStatus: String, CaseIterable, Sendable, Hashable {
    case connected
    case updating
    case partial
    case failed

    public var text: String {
        switch self {
        case .connected: "Connected"
        case .updating: "Updating proposals"
        case .partial: "Partial context"
        case .failed: "Action failed"
        }
    }

    public var glyph: String {
        switch self {
        case .connected: "link.circle.fill"
        case .updating: "sparkles"
        case .partial: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    public var tone: Color {
        switch self {
        case .connected: OpenPawTheme.signal
        case .updating: OpenPawTheme.pulse
        case .partial: OpenPawTheme.caution
        case .failed: OpenPawTheme.bad
        }
    }
}

public enum LauncherMotionTransition: Sendable, Hashable {
    case flyingArc
    case fadeAndScale
}

public enum LauncherMotionPolicy {
    public nonisolated static func transition(reduceMotion: Bool) -> LauncherMotionTransition {
        reduceMotion ? .fadeAndScale : .flyingArc
    }
}

/// Compact, text-free launcher control. Its semantic status remains available to assistive technologies.
public struct PawOrbView: View {
    private let status: LauncherStatus
    private let isActive: Bool

    public init(status: LauncherStatus, isActive: Bool = false) {
        self.status = status
        self.isActive = isActive
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.13), OpenPawTheme.graphite, OpenPawTheme.void],
                        center: UnitPoint(x: 0.35, y: 0.28),
                        startRadius: 1,
                        endRadius: 36
                    )
                )
                .overlay(
                    Circle().stroke(
                        AngularGradient(
                            colors: [OpenPawTheme.signal, OpenPawTheme.pulse, OpenPawTheme.lineStrong, OpenPawTheme.signal],
                            center: .center
                        ),
                        lineWidth: isActive ? 2.4 : 1.5
                    )
                )
                .shadow(color: OpenPawTheme.signal.opacity(isActive ? 0.32 : 0.15), radius: isActive ? 12 : 7, y: 3)

            PawMark()
                .fill(
                    LinearGradient(
                        colors: [OpenPawTheme.textPrimary.opacity(0.92), OpenPawTheme.textSecondary.opacity(0.58)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(PawMark().stroke(Color.white.opacity(0.1), lineWidth: 0.6))
                .padding(13)
                .shadow(color: .black.opacity(0.55), radius: 2, y: 1)

            Circle()
                .fill(status.tone)
                .frame(width: 7, height: 7)
                .offset(x: 17, y: 17)
                .overlay(Circle().stroke(OpenPawTheme.void, lineWidth: 1).frame(width: 9, height: 9).offset(x: 17, y: 17))
        }
        .frame(width: PawOrbPresentation.visualDiameter, height: PawOrbPresentation.visualDiameter)
        .frame(width: PawOrbPresentation.hitDiameter, height: PawOrbPresentation.hitDiameter)
        .contentShape(Circle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Paw launcher")
        .accessibilityValue("\(status.text), \(status.glyph)")
    }
}

private struct PawMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        path.addEllipse(in: CGRect(x: w * 0.27, y: h * 0.43, width: w * 0.46, height: h * 0.48))
        path.addEllipse(in: CGRect(x: w * 0.08, y: h * 0.20, width: w * 0.23, height: h * 0.29))
        path.addEllipse(in: CGRect(x: w * 0.30, y: h * 0.04, width: w * 0.22, height: h * 0.30))
        path.addEllipse(in: CGRect(x: w * 0.54, y: h * 0.07, width: w * 0.22, height: h * 0.30))
        path.addEllipse(in: CGRect(x: w * 0.73, y: h * 0.25, width: w * 0.21, height: h * 0.28))
        return path
    }
}
