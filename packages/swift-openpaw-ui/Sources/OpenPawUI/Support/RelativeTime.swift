import SwiftUI

/// The age of something, in the fewest characters that still say it.
///
/// Timestamps in this app are almost never read as clock times — they are read as "how stale is this". So the
/// display form is a single magnitude, never localized and never abbreviated differently at different sizes, and
/// only drops back to a calendar date once "6d" stops being useful. `now` is injectable because a formatter that
/// reads the system clock cannot be tested, and this one is asserted.
public struct RelativeTime: View {
    private let date: Date
    private let now: Date
    private let tone: Color

    public init(date: Date, now: Date = Date(), tone: Color = OpenPawTheme.textTertiary) {
        self.date = date
        self.now = now
        self.tone = tone
    }

    public var body: some View {
        Text(Self.short(date, now: now))
            .font(OpenPawTheme.Machine.codeSmall)
            // Digits share a width, so a value ticking 58s -> 59s -> 1m never nudges its neighbours.
            .monospacedDigit()
            .foregroundStyle(tone)
            .accessibilityLabel(Self.spoken(date, now: now))
    }

    // MARK: - Formatting

    /// Six brackets: `now`, `12s`, `4m`, `3h`, `2d`, then a calendar date like `Aug 20`.
    public static func short(_ date: Date, now: Date = Date()) -> String {
        let elapsed = now.timeIntervalSince(date)
        // A timestamp from the near future is a clock skew between phone and host, not news. It reads as now.
        if elapsed < 2 { return "now" }
        if elapsed < 60 { return "\(Int(elapsed))s" }
        if elapsed < 3_600 { return "\(Int(elapsed / 60))m" }
        if elapsed < 86_400 { return "\(Int(elapsed / 3_600))h" }
        if elapsed < 604_800 { return "\(Int(elapsed / 86_400))d" }
        return calendarDate(date)
    }

    /// What VoiceOver says. "12s" spoken aloud is noise; "12 seconds ago" is the information.
    public static func spoken(_ date: Date, now: Date = Date()) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 2 { return "just now" }
        if elapsed < 60 { return count(Int(elapsed), "second") }
        if elapsed < 3_600 { return count(Int(elapsed / 60), "minute") }
        if elapsed < 86_400 { return count(Int(elapsed / 3_600), "hour") }
        if elapsed < 604_800 { return count(Int(elapsed / 86_400), "day") }
        return calendarDate(date)
    }

    private static func count(_ value: Int, _ unit: String) -> String {
        "\(value) \(unit)\(value == 1 ? "" : "s") ago"
    }

    /// `MMM d` built from a fixed table rather than a `DateFormatter`: no locale to vary, no formatter to
    /// allocate per row, and a value a test can assert exactly.
    private static func calendarDate(_ date: Date) -> String {
        let calendar = Calendar.current
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        let name = monthNames.indices.contains(month - 1) ? monthNames[month - 1] : "—"
        return "\(name) \(day)"
    }

    private static let monthNames = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]
}
