import Foundation

/// Characters that never need quoting in POSIX shells.
private let shellSafeScalars: Set<Character> = {
    var set = Set<Character>()
    for scalar in UInt8(ascii: "a")...UInt8(ascii: "z") { set.insert(Character(UnicodeScalar(scalar))) }
    for scalar in UInt8(ascii: "A")...UInt8(ascii: "Z") { set.insert(Character(UnicodeScalar(scalar))) }
    for scalar in UInt8(ascii: "0")...UInt8(ascii: "9") { set.insert(Character(UnicodeScalar(scalar))) }
    for character in "_-./:@%+=" { set.insert(character) }
    return set
}()

/// Quotes `value` so a POSIX shell passes it through as a single literal word.
///
/// Single quoting is used because it suppresses every form of expansion
/// (`$`, backtick, `~`, glob, history) and preserves newlines verbatim. Embedded
/// single quotes are closed, escaped and reopened (`'\''`), which is the only
/// safe encoding for them inside a single quoted word.
public func shellQuoted(_ value: String) -> String {
    if !value.isEmpty, value.allSatisfy({ shellSafeScalars.contains($0) }) {
        return value
    }
    return "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
}

/// Formats a duration the way OpenPaw shows it in fallback and restoration
/// copy: coarse, deterministic and never localized (these strings are asserted
/// by tests and mirrored by the Rust host).
public func formatApproximateDuration(_ interval: TimeInterval) -> String {
    let total = Int(max(0, interval).rounded())
    if total < 60 { return "\(total)s" }
    let minutes = total / 60
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    let residualMinutes = minutes % 60
    if hours < 24 {
        return residualMinutes == 0 ? "\(hours)h" : "\(hours)h \(residualMinutes)m"
    }
    let days = hours / 24
    let residualHours = hours % 24
    return residualHours == 0 ? "\(days)d" : "\(days)d \(residualHours)h"
}
