import SwiftUI

/// "The agent is working" — as a scanline, not a spinner.
///
/// A spinner says nothing except that something is happening. This says what is happening (the tool's name, or
/// `thinking` when the agent is between tools) and proves it is still happening by advancing a single block one
/// cell per second across a fixed-width field. One cell per second is deliberately slow: it reads as a machine
/// ticking rather than a UI trying to look busy, and at 1 Hz it costs one redraw a second.
///
/// This is one of exactly two animations in the app. With reduce-motion on it renders the same line with a steady
/// block — still legible as "working", with nothing moving.
public struct WorkingIndicator: View {
    private let label: String?
    private let width: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(label: String? = nil, width: Int = 14) {
        self.label = label
        self.width = max(1, width)
    }

    private var name: String { label ?? "thinking" }

    public var body: some View {
        HStack(spacing: OpenPawTheme.Space.small) {
            Text(name)
                .font(OpenPawTheme.Machine.codeSmall)
                .foregroundStyle(OpenPawTheme.textSecondary)
                .lineLimit(1)

            if reduceMotion {
                field(at: 0)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    field(at: cell(at: context.date))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label.map { "working, \($0)" } ?? "thinking")
    }

    /// The field is a row of equal cells rather than a padded string: leading and trailing spaces in a `Text` are
    /// not reliably preserved by layout, and a jittering block would defeat the point.
    private func field(at position: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<width, id: \.self) { index in
                Text("\u{2588}")
                    .font(OpenPawTheme.Machine.codeSmall)
                    .foregroundStyle(OpenPawTheme.textTertiary)
                    .opacity(index == position ? 1 : 0)
            }
        }
        .background(alignment: .leading) {
            Rectangle()
                .fill(OpenPawTheme.line)
                .frame(height: 1)
        }
    }

    /// Wall-clock derived rather than state-derived, so every indicator on screen ticks in step and none of them
    /// needs a timer of its own.
    private func cell(at date: Date) -> Int {
        let seconds = Int(date.timeIntervalSinceReferenceDate.rounded(.down))
        return ((seconds % width) + width) % width
    }
}

#Preview("Working") {
    VStack(alignment: .leading, spacing: OpenPawTheme.Space.large) {
        WorkingIndicator(label: "Bash")
        WorkingIndicator()
        WorkingIndicator(label: "Read", width: 24)
        WorkingIndicator(label: "Bash")
    }
    .padding(OpenPawTheme.Space.xl)
    .background(OpenPawTheme.ink)
}
