import Foundation

/// Why a transport occupies its slot in the plan.
public enum SelectionReason: String, Sendable, Hashable, Codable {
    /// The user pinned this transport on the host.
    case pinned = "pinned"
    /// This transport connected last time.
    case lastKnownGood = "last_known_good"
    /// Preferred by default because it survives roaming and hides latency.
    case latencyPreference = "latency_preference"
    /// Tried only if everything above it failed.
    case fallback = "fallback"

    public var explanation: String {
        switch self {
        case .pinned: return "pinned for this host"
        case .lastKnownGood: return "last known good for this host"
        case .latencyPreference: return "preferred for latency"
        case .fallback: return "fallback"
        }
    }
}

/// One step of the `auto` connection plan.
public struct TransportAttempt: Sendable, Hashable, Codable {
    public let kind: TransportKind
    /// Zero-based position in the plan.
    public let priority: Int
    public let reason: SelectionReason

    public init(kind: TransportKind, priority: Int, reason: SelectionReason) {
        self.kind = kind
        self.priority = priority
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case kind, priority, reason
    }
}

/// The `auto` transport policy.
///
/// Default preference is mosh → Eternal Terminal → SSH: mosh gives local echo
/// and survives IP changes, ET reconnects but echoes remotely, SSH always works.
/// A host's pinned choice comes first, then whatever succeeded last time (see
/// ``HostStore/recordSuccessfulTransport(_:for:)``, which is where that fact is
/// persisted), then the default order. Transports absent from `available` — not
/// compiled into this build — never appear in a plan.
public struct TransportSelector: Sendable {
    /// Default order, best first.
    public static let canonicalOrder: [TransportKind] = [.mosh, .eternalTerminal, .ssh]

    public init() {}

    public func plan(for host: HostRecord, available: Set<TransportKind>) -> [TransportAttempt] {
        var ordered: [(kind: TransportKind, reason: SelectionReason)] = []

        func push(_ kind: TransportKind, _ reason: SelectionReason) {
            guard available.contains(kind) else { return }
            guard !ordered.contains(where: { $0.kind == kind }) else { return }
            ordered.append((kind, reason))
        }

        if let pinned = host.preferredTransport { push(pinned, .pinned) }
        if let known = host.lastSuccessfulTransport { push(known, .lastKnownGood) }
        for kind in Self.canonicalOrder {
            push(kind, kind == .mosh ? .latencyPreference : .fallback)
        }

        return ordered.enumerated().map {
            TransportAttempt(kind: $0.element.kind, priority: $0.offset, reason: $0.element.reason)
        }
    }

    /// The sentence the UI shows after a fallback, e.g.
    /// "Eternal Terminal (last known good for this host) failed: connection
    /// refused by beta.local:2022. Mosh (preferred for latency) failed: Mosh is
    /// not installed on the host (`mosh-server` not found). Continued with SSH."
    public func explain(_ outcome: [TransportAttempt: TransportError]) -> String {
        guard !outcome.isEmpty else {
            return "The preferred transport connected; no fallback was needed."
        }
        let ordered = outcome.sorted {
            ($0.key.priority, $0.key.kind.rawValue) < ($1.key.priority, $1.key.kind.rawValue)
        }
        var sentences = ordered.map { attempt, error in
            "\(attempt.kind.displayName) (\(attempt.reason.explanation)) failed: \(error)."
        }
        // SSH needs nothing on the host beyond sshd, so it is the last resort in
        // every plan: if it is not among the failures, it is what carried the
        // session.
        if outcome.keys.contains(where: { $0.kind == .ssh }) {
            sentences.append("No transport was able to connect.")
        } else {
            sentences.append("Continued with \(TransportKind.ssh.displayName).")
        }
        return sentences.joined(separator: " ")
    }
}
