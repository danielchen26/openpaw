import Foundation

/// Whether the app content may be shown, or must be re-authenticated first.
///
/// Deliberately three-valued: "we cannot authenticate on this device" is a different situation from
/// "authenticate now", and collapsing them either locks a passcode-less device out of its own data forever or
/// silently disables the lock. The UI must handle both.
enum GateDecision: Equatable, Sendable {
    /// Show the content.
    case unlocked
    /// Hide the content and evaluate the local authentication policy.
    case authenticate
    /// Hide the content and explain that this device cannot satisfy the gate. Carries the reason verbatim so the
    /// screen states what happened rather than a generic failure.
    case unavailable(reason: String)
}

/// Why the app is asking. Used only for copy, but kept in the model so the prompt reason is decided by the same
/// pure function that decides to prompt at all.
enum GateTrigger: Equatable, Sendable {
    case launch
    case returnedFromBackground(awayFor: TimeInterval)
}

/// The persisted user preference plus the clock-independent inputs the decision needs.
struct GatePolicy: Equatable, Sendable {
    /// User setting. When false the gate never engages.
    var requiresBiometrics: Bool
    /// How long the app may sit in the background before it re-locks. Zero means "lock every time".
    var graceInterval: TimeInterval
    /// Set by the app when `LAContext.canEvaluatePolicy` fails, with the localized reason.
    var unavailableReason: String?

    static let `default` = GatePolicy(requiresBiometrics: true, graceInterval: 120, unavailableReason: nil)

    /// The grace intervals offered in Settings. Ninety seconds of slack covers switching to the authenticator app
    /// or reading a notification; anything longer stops being a lock.
    static let offeredGraceIntervals: [TimeInterval] = [0, 30, 120, 600]

    static func graceLabel(_ interval: TimeInterval) -> String {
        switch interval {
        case 0: "Every time"
        case ..<60: "After \(Int(interval)) seconds"
        case 60: "After 1 minute"
        default: "After \(Int(interval / 60)) minutes"
        }
    }
}

/// The pure re-gate decision. Every branch here is a decision the app must never make differently in two places,
/// so no part of it lives in a view or in a lifecycle callback.
enum BiometricGate {

    /// - Parameters:
    ///   - policy: the user's setting and the device's capability.
    ///   - lastUnlockedAt: when authentication last succeeded, or `nil` if it never has this launch.
    ///   - leftForegroundAt: when the app last stopped being frontmost, or `nil` if it has not since the last
    ///     unlock (cold launch, or the app never backgrounded).
    ///   - now: the current instant, injected so the decision is testable and so a single call site cannot read
    ///     the clock twice and straddle a boundary.
    static func decide(
        policy: GatePolicy,
        lastUnlockedAt: Date?,
        leftForegroundAt: Date?,
        now: Date
    ) -> GateDecision {
        // The setting wins over everything, including an unavailable biometric sensor: a user who turned the lock
        // off is not asking to be told their sensor is broken.
        guard policy.requiresBiometrics else { return .unlocked }

        if let reason = policy.unavailableReason {
            return .unavailable(reason: reason)
        }

        // Cold launch, or a previous attempt that never succeeded.
        guard let lastUnlockedAt else { return .authenticate }

        // Foreground the whole time since the last unlock: nothing has happened that could have exposed the
        // screen to someone else.
        guard let leftForegroundAt else { return .unlocked }

        // A background episode that began before the last successful unlock is already accounted for by that
        // unlock. Comparing the two timestamps rather than clearing the background marker keeps this function
        // total: it cannot be desynchronised by a missed lifecycle callback.
        if leftForegroundAt <= lastUnlockedAt { return .unlocked }

        // Zero grace means re-lock on every trip through the background, and short-circuits before the clock is
        // consulted at all so a wall-clock jump cannot weaken it.
        if policy.graceInterval <= 0 { return .authenticate }

        let away = now.timeIntervalSince(leftForegroundAt)

        // A clock that moved backwards makes the elapsed interval meaningless. The safe reading of an
        // untrustworthy clock is that the grace period expired.
        if away < 0 { return .authenticate }

        return away >= policy.graceInterval ? .authenticate : .unlocked
    }

    /// The sentence shown in the system authentication sheet. It names the thing being protected, because
    /// "Authenticate" tells the user nothing about what they are authorising.
    static func prompt(for trigger: GateTrigger) -> String {
        switch trigger {
        case .launch:
            "Unlock OpenPaw to see your agent sessions and approve requests."
        case .returnedFromBackground(let away):
            "OpenPaw locked after \(formattedAway(away)) away. Unlock to approve requests again."
        }
    }

    static func formattedAway(_ interval: TimeInterval) -> String {
        let seconds = Int(max(0, interval).rounded())
        if seconds < 60 { return "\(seconds) seconds" }
        let minutes = seconds / 60
        if minutes < 60 { return minutes == 1 ? "a minute" : "\(minutes) minutes" }
        let hours = minutes / 60
        return hours == 1 ? "an hour" : "\(hours) hours"
    }
}
