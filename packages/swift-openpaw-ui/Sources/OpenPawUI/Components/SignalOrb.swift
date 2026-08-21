import SwiftUI

public enum ConnectionSignalState: String, CaseIterable, Sendable, Hashable {
    case discovering
    case connecting
    case online
    case degraded
    case offline
    case failed
    case blocked
}

public enum ConnectionSignalTone: String, CaseIterable, Sendable, Hashable {
    case quiet
    case signal
    case pulse
    case caution
    case blocked

    public var color: Color {
        switch self {
        case .quiet: OpenPawTheme.textSecondary
        case .signal: OpenPawTheme.signal
        case .pulse: OpenPawTheme.pulse
        case .caution: OpenPawTheme.caution
        case .blocked: OpenPawTheme.bad
        }
    }
}

public struct ConnectionSignal: Sendable, Hashable, Identifiable {
    public let state: ConnectionSignalState

    public var id: ConnectionSignalState { state }

    public init(_ state: ConnectionSignalState) {
        self.state = state
    }

    public init(availability: DeviceAvailabilityPresentation) {
        switch availability {
        case .unknown: self.init(.discovering)
        case .connecting: self.init(.connecting)
        case .online: self.init(.online)
        case .offline: self.init(.offline)
        case .failed: self.init(.failed)
        }
    }

    public var label: String {
        switch state {
        case .discovering: "Discovering"
        case .connecting: "Connecting"
        case .online: "Online"
        case .degraded: "Degraded"
        case .offline: "Offline"
        case .failed: "Failed"
        case .blocked: "Blocked"
        }
    }

    public var glyph: String {
        switch state {
        case .discovering: "dot.radiowaves.left.and.right"
        case .connecting: "arrow.triangle.2.circlepath"
        case .online: "checkmark.circle.fill"
        case .degraded: "exclamationmark.triangle.fill"
        case .offline: "moon.zzz.fill"
        case .failed: "xmark.octagon.fill"
        case .blocked: "lock.trianglebadge.exclamationmark.fill"
        }
    }

    public var tone: ConnectionSignalTone {
        switch state {
        case .discovering: .quiet
        case .connecting: .signal
        case .online: .pulse
        case .degraded: .caution
        case .offline: .quiet
        case .failed: .caution
        case .blocked: .blocked
        }
    }

    public var accessibilityLabel: String {
        "Connection status: \(label)"
    }

    public var rotatesWhenAllowed: Bool {
        state == .discovering || state == .connecting || state == .degraded
    }
}

public struct SignalOrbMotionPolicy: Sendable, Hashable {
    public let rotates: Bool

    public init(rotates: Bool) {
        self.rotates = rotates
    }
}

public struct SignalOrb: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private let signal: ConnectionSignal
    private let size: CGFloat

    public init(signal: ConnectionSignal, size: CGFloat = 18) {
        self.signal = signal
        self.size = size
    }

    public init(_ state: ConnectionSignalState, size: CGFloat = 18) {
        self.init(signal: ConnectionSignal(state), size: size)
    }

    public nonisolated static func motionPolicy(
        reduceMotion: Bool,
        appIsActive: Bool,
        signal: ConnectionSignalState
    ) -> SignalOrbMotionPolicy {
        let semantic = ConnectionSignal(signal)
        return SignalOrbMotionPolicy(rotates: !reduceMotion && appIsActive && semantic.rotatesWhenAllowed)
    }

    public var body: some View {
        let policy = Self.motionPolicy(
            reduceMotion: reduceMotion,
            appIsActive: scenePhase == .active,
            signal: signal.state
        )

        TimelineView(.animation(paused: !policy.rotates)) { context in
            let angle = policy.rotates ? context.date.timeIntervalSinceReferenceDate.remainder(dividingBy: 2.4) / 2.4 * 360 : 0
            ZStack {
                Circle()
                    .stroke(OpenPawTheme.lineStrong, lineWidth: OpenPawTheme.hairline)
                    .background(Circle().fill(OpenPawTheme.void))
                Circle()
                    .fill(signal.tone.color)
                    .frame(width: max(size * 0.34, 4), height: max(size * 0.34, 4))
                    .offset(x: size * 0.28)
                    .rotationEffect(.degrees(angle))
                Image(systemName: signal.glyph)
                    .font(.system(.caption2, design: .rounded, weight: .semibold))
                    .foregroundStyle(signal.tone.color)
                    .opacity(0.9)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(signal.accessibilityLabel))
    }
}
