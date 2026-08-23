import CoreGraphics
import Foundation

/// A root-level horizontal gesture after child surfaces have described whether they currently own it.
///
/// Keeping this value independent of SwiftUI and UIKit gives both the policy tests and the production recognizer
/// one contract. Task-specific views only mark exclusions; they do not each invent gesture thresholds.
public struct DestinationPagingGesture: Sendable, Equatable {
    public let translationX: CGFloat
    public let translationY: CGFloat
    public let velocityX: CGFloat
    public let startX: CGFloat
    public let isBackNavigationAvailable: Bool
    public let isModalPresented: Bool
    public let isHorizontalChildControlActive: Bool
    public let isTextSelectionActive: Bool
    public let isInboxRowActionActive: Bool

    public init(
        translationX: CGFloat,
        translationY: CGFloat,
        velocityX: CGFloat,
        startX: CGFloat,
        isBackNavigationAvailable: Bool = false,
        isModalPresented: Bool = false,
        isHorizontalChildControlActive: Bool = false,
        isTextSelectionActive: Bool = false,
        isInboxRowActionActive: Bool = false
    ) {
        self.translationX = translationX
        self.translationY = translationY
        self.velocityX = velocityX
        self.startX = startX
        self.isBackNavigationAvailable = isBackNavigationAvailable
        self.isModalPresented = isModalPresented
        self.isHorizontalChildControlActive = isHorizontalChildControlActive
        self.isTextSelectionActive = isTextSelectionActive
        self.isInboxRowActionActive = isInboxRowActionActive
    }
}

public enum DestinationPageSuppression: Sendable, Equatable {
    case insufficientDistance
    case insufficientVelocity
    case verticalDominance
    case leadingEdgeBack
    case activeModal
    case activeHorizontalChildControl
    case textSelection
    case inboxRowAction
    case boundary
}

public enum DestinationPageDecision: Sendable, Equatable {
    case previous
    case next
    case ignore(DestinationPageSuppression)
}

public struct DestinationKeyboardModifiers: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let command = DestinationKeyboardModifiers(rawValue: 1 << 0)
    public static let option = DestinationKeyboardModifiers(rawValue: 1 << 1)
    public static let shift = DestinationKeyboardModifiers(rawValue: 1 << 2)
    public static let control = DestinationKeyboardModifiers(rawValue: 1 << 3)
}

public enum DestinationKeyboardKey: Sendable, Equatable {
    case leftArrow
    case rightArrow
    case other
}

/// Hardware keyboard paging is deliberately an exact chord so ordinary cursor navigation remains local to editors.
public enum DestinationKeyboardShortcutPolicy {
    public static func decision(
        key: DestinationKeyboardKey,
        modifiers: DestinationKeyboardModifiers
    ) -> DestinationPageDecision? {
        guard modifiers == [.command, .option] else { return nil }
        return switch key {
        case .leftArrow: .previous
        case .rightArrow: .next
        case .other: nil
        }
    }
}

/// The one source of truth for root destination paging.
///
/// It deliberately requires both travel and velocity. Travel alone makes slow horizontal scrolling change tabs;
/// velocity alone turns a short diagonal flick into navigation. Horizontal dominance is a third independent gate.
public enum DestinationPagingPolicy {
    public static let minimumDistance: CGFloat = 48
    public static let minimumVelocity: CGFloat = 400
    public static let horizontalDominance: CGFloat = 1.25
    public static let leadingEdgeWidth: CGFloat = 24

    public static func decision(
        from current: ShellDestination,
        gesture: DestinationPagingGesture
    ) -> DestinationPageDecision {
        if gesture.isModalPresented { return .ignore(.activeModal) }
        if gesture.isHorizontalChildControlActive { return .ignore(.activeHorizontalChildControl) }
        if gesture.isTextSelectionActive { return .ignore(.textSelection) }
        if gesture.isInboxRowActionActive { return .ignore(.inboxRowAction) }
        if gesture.isBackNavigationAvailable,
           gesture.startX <= leadingEdgeWidth,
           gesture.translationX > 0 {
            return .ignore(.leadingEdgeBack)
        }

        guard abs(gesture.translationX) >= minimumDistance else {
            return .ignore(.insufficientDistance)
        }
        guard abs(gesture.velocityX) >= minimumVelocity,
              gesture.translationX * gesture.velocityX > 0 else {
            return .ignore(.insufficientVelocity)
        }
        guard abs(gesture.translationX) >= abs(gesture.translationY) * horizontalDominance else {
            return .ignore(.verticalDominance)
        }

        let direction: DestinationPageDecision = gesture.translationX < 0 ? .next : .previous
        guard destination(after: direction, from: current) != current else {
            return .ignore(.boundary)
        }
        return direction
    }

    /// One decision advances at most one element and clamps at both ends.
    public static func destination(
        after decision: DestinationPageDecision,
        from current: ShellDestination
    ) -> ShellDestination {
        guard let index = ShellDestination.allCases.firstIndex(of: current) else { return current }
        let candidate: Int
        switch decision {
        case .previous:
            candidate = index - 1
        case .next:
            candidate = index + 1
        case .ignore:
            return current
        }
        guard ShellDestination.allCases.indices.contains(candidate) else { return current }
        return ShellDestination.allCases[candidate]
    }
}
