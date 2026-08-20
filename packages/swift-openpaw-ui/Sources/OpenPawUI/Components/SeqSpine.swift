import SwiftUI

/// The left gutter of Chat View and the event log: an event's `seq` over a vertical rule.
///
/// The number earns its column because it is not decoration — it is the exact resume point for
/// `GET /v1/events?after_seq=`, so a person reading a transcript can hand a number to a colleague or a support
/// ticket and get the same bytes back. The width is derived from the widest number in the list rather than from
/// the number in this row, so the rule stays put as the session runs from `seq 9` to `seq 10` instead of shunting
/// every row sideways.
public struct SeqSpine: View {
    private let seq: UInt64
    private let widestSeq: UInt64?
    private let glyph: String?
    private let tone: Color

    public init(
        seq: UInt64,
        widestSeq: UInt64? = nil,
        glyph: String? = nil,
        tone: Color = OpenPawTheme.textTertiary
    ) {
        self.seq = seq
        self.widestSeq = widestSeq
        self.glyph = glyph
        self.tone = tone
    }

    /// At least three columns: a session that has just started should not re-flow the moment it reaches `seq 100`.
    private var digits: Int {
        let widest = max(widestSeq ?? seq, seq)
        return max(3, String(widest).count)
    }

    public var body: some View {
        VStack(spacing: OpenPawTheme.Space.tight) {
            // A hidden run of zeroes reserves the column, so the spine keeps its width at every Dynamic Type
            // size where a hard-coded one would clip or drift.
            //
            // `ZStack`, not `overlay`: an overlay is offered exactly its host's measured size, which wraps or
            // clips the number the moment text layout rounds the two differently. In a `ZStack` each child
            // sizes itself and the stack takes the wider of the two.
            ZStack(alignment: .trailing) {
                Text(String(repeating: "0", count: digits))
                    .font(OpenPawTheme.Machine.codeSmall)
                    .monospacedDigit()
                    .hidden()
                Text(String(seq))
                    .font(OpenPawTheme.Machine.codeSmall)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(tone)
            }

            if let glyph {
                Image(systemName: glyph)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(tone)
            }

            Rectangle()
                .fill(OpenPawTheme.line)
                .frame(width: 1)
                .frame(maxHeight: .infinity)
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("event \(seq)")
    }
}

#Preview("Spine") {
    HStack(alignment: .top, spacing: OpenPawTheme.Space.medium) {
        VStack(alignment: .leading, spacing: 0) {
            ForEach([UInt64(8), 9, 10, 118], id: \.self) { seq in
                HStack(alignment: .top, spacing: OpenPawTheme.Space.medium) {
                    SeqSpine(seq: seq, widestSeq: 118, glyph: "terminal")
                    Text("tool.started")
                        .font(OpenPawTheme.Machine.body)
                        .foregroundStyle(OpenPawTheme.textPrimary)
                        .padding(.bottom, OpenPawTheme.Space.large)
                }
                .frame(height: 64)
            }
        }
        Spacer()
    }
    .padding(OpenPawTheme.Space.large)
    .background(OpenPawTheme.ink)
}
