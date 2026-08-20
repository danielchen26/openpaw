import Foundation
import OpenPawProtocol
import SwiftUI

// MARK: - Mini diff

/// One line of a patch, with the numbering it had in the file it came from.
public struct MiniDiffLine: Identifiable, Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case added
        case removed
        case context
    }

    /// Position in parse order. A patch has no other stable identity, and two identical lines in one hunk are
    /// genuinely different lines.
    public let id: Int
    public let kind: Kind
    /// Line number in the pre-image, or `nil` for an added line that has no pre-image.
    public let oldLine: Int?
    /// Line number in the post-image, or `nil` for a removed line that is not in it.
    public let newLine: Int?
    /// Content with the leading `+`, `-` or space marker removed.
    public let text: String

    public init(id: Int, kind: Kind, oldLine: Int?, newLine: Int?, text: String) {
        self.id = id
        self.kind = kind
        self.oldLine = oldLine
        self.newLine = newLine
        self.text = text
    }
}

/// A unified diff parsed just far enough to render a few lines inline.
///
/// The agent hands us `unified_diff` on a file change event, so a small patch can be shown without a round trip to
/// the host for a full diff. This is deliberately not a diff *engine*: it computes nothing, it only reads the
/// numbering the patch already states, which is why it cannot disagree with the host's own diff view.
public struct MiniDiff: Sendable, Hashable {
    public let lines: [MiniDiffLine]
    /// Number of `@@` hunks the patch declared.
    public let hunkCount: Int

    public init(lines: [MiniDiffLine], hunkCount: Int) {
        self.lines = lines
        self.hunkCount = hunkCount
    }

    public var added: Int { lines.filter { $0.kind == .added }.count }
    public var removed: Int { lines.filter { $0.kind == .removed }.count }
    public var context: Int { lines.filter { $0.kind == .context }.count }
    public var isEmpty: Bool { lines.isEmpty }

    /// Parses a unified diff. Headers, mode changes, rename markers and the `\ No newline` note are dropped;
    /// anything before the first hunk header is preamble and cannot carry line numbers, so it is dropped too.
    public static func parse(_ patch: String) -> MiniDiff {
        var lines: [MiniDiffLine] = []
        var hunks = 0
        var oldCursor = 0
        var newCursor = 0
        var inHunk = false

        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)

            if let header = hunkHeader(line) {
                hunks += 1
                oldCursor = header.old
                newCursor = header.new
                inHunk = true
                continue
            }

            guard inHunk else { continue }
            if line.hasPrefix("\\") { continue }

            let index = lines.count
            switch line.first {
            case "+":
                lines.append(MiniDiffLine(
                    id: index, kind: .added, oldLine: nil, newLine: newCursor, text: String(line.dropFirst())
                ))
                newCursor += 1
            case "-":
                lines.append(MiniDiffLine(
                    id: index, kind: .removed, oldLine: oldCursor, newLine: nil, text: String(line.dropFirst())
                ))
                oldCursor += 1
            case " ":
                lines.append(MiniDiffLine(
                    id: index, kind: .context, oldLine: oldCursor, newLine: newCursor,
                    text: String(line.dropFirst())
                ))
                oldCursor += 1
                newCursor += 1
            case nil:
                // An empty line inside a hunk is an unchanged empty line whose marker space was stripped in
                // transit. Dropping it would misnumber everything after it.
                lines.append(MiniDiffLine(
                    id: index, kind: .context, oldLine: oldCursor, newLine: newCursor, text: ""
                ))
                oldCursor += 1
                newCursor += 1
            default:
                // A trailing `diff --git` for the next file, or `index abc..def`. Leave the hunk.
                inHunk = false
            }
        }

        return MiniDiff(lines: lines, hunkCount: hunks)
    }

    /// Reads `@@ -12,7 +12,9 @@ optional trailing context`. The counts are optional in the format
    /// (`@@ -1 +1 @@` is legal for a single-line hunk) and are not needed here — only the start numbers are.
    static func hunkHeader(_ line: String) -> (old: Int, new: Int)? {
        guard line.hasPrefix("@@") else { return nil }
        let body = line.dropFirst(2)
        guard let close = body.range(of: "@@") else { return nil }
        var old: Int?
        var new: Int?
        for token in body[body.startIndex..<close.lowerBound].split(separator: " ") {
            guard let sign = token.first, sign == "-" || sign == "+" else { continue }
            guard let start = token.dropFirst().split(separator: ",").first.flatMap({ Int($0) }) else { continue }
            if sign == "-" { old = start } else { new = start }
        }
        guard let old, let new else { return nil }
        return (old, new)
    }
}

// MARK: - Settled permissions

extension PermissionRow {
    /// True once the matching `permission.resolved` has arrived. A settled row must never render as a live prompt:
    /// offering a decision that has already been taken invites a double approval.
    public var isSettled: Bool { decision != nil }

    /// Past tense, because it happened: `Approved once · from this device`.
    public var settledDescription: String? {
        guard let decision else { return nil }
        let verb =
            switch decision {
            case .approveOnce: "Approved once"
            case .approveAlways: "Approved always"
            case .deny: "Denied"
            case .denyAlways: "Denied always"
            case .answer: "Answered"
            case .stop: "Stopped"
            case .acknowledge: "Acknowledged"
            }
        guard let decidedBy else { return verb }
        let source =
            switch decidedBy {
            case .device: "from this device"
            case .terminal: "in the terminal"
            case .policy: "by policy"
            case .timeout: "by timeout"
            }
        return "\(verb) · \(source)"
    }

    /// `true` when the row still wants a decision from a person.
    public var isLive: Bool { !isSettled }
}

// MARK: - Prose

/// The human register. This is what was *said* — the only rows on this screen a person wrote or the model wrote
/// as prose. User and assistant are told apart by which edge the card is anchored to and by the micro-label, not
/// by a coloured bubble: colour belongs to risk.
public struct ProseCard: View {
    public let row: ProseRow

    public init(row: ProseRow) {
        self.row = row
    }

    private var isUser: Bool { row.role == .user }

    public var body: some View {
        HumanPanel {
            VStack(alignment: isUser ? .trailing : .leading, spacing: OpenPawTheme.Space.small) {
                Text(isUser ? "you" : "agent").microLabel(OpenPawTheme.textSecondary)
                Text(prose)
                    .font(OpenPawTheme.Human.prose)
                    .foregroundStyle(OpenPawTheme.textPrimary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(.leading, isUser ? OpenPawTheme.Space.xxl : 0)
        .padding(.trailing, isUser ? 0 : OpenPawTheme.Space.xxl)
    }

    /// Agent prose is markdown. Inline-only interpretation keeps hard line breaks intact, which matters because
    /// agents lay out lists and paths by hand.
    private var prose: AttributedString {
        (try? AttributedString(
            markdown: row.text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(row.text)
    }
}

// MARK: - Thinking

/// Reasoning traces are machine register and start collapsed. They are the agent talking to itself: useful when
/// you are debugging a bad turn, noise the rest of the time, and never worth pushing the conversation off screen.
public struct ThinkingCard: View {
    public let row: ThinkingRow

    @State private var isExpanded = false

    public init(row: ThinkingRow) {
        self.row = row
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
            Text("thinking").microLabel()

            Text(row.text)
                .font(OpenPawTheme.Machine.body)
                .foregroundStyle(OpenPawTheme.textTertiary)
                .lineLimit(isExpanded ? nil : 3)
                .textSelection(.enabled)

            Button {
                isExpanded.toggle()
            } label: {
                Label(
                    isExpanded ? "Hide thinking" : "Show thinking",
                    systemImage: isExpanded ? "chevron.up" : "chevron.down"
                )
                .font(OpenPawTheme.Machine.label)
                .textCase(.uppercase)
                .tracking(0.9)
                .foregroundStyle(OpenPawTheme.textSecondary)
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, OpenPawTheme.Space.medium)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(OpenPawTheme.line)
                .frame(width: OpenPawTheme.hairline * 3)
        }
    }
}

// MARK: - Tool call

/// One tool call, merged from up to four events into one card that mutates in place. Machine register throughout:
/// this is the record of what the machine actually ran.
public struct ToolCard: View {
    /// Output beyond this is behind a disclosure. Twelve lines is about the tail of a test run — enough to see
    /// what happened without burying the next row.
    static let outputPreviewLines = 12

    public let row: ToolRow
    public let onOpenFile: (String) -> Void

    @State private var showsAllOutput = false

    public init(row: ToolRow, onOpenFile: @escaping (String) -> Void) {
        self.row = row
        self.onOpenFile = onOpenFile
    }

    public var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                header

                if let summary = row.summary, !summary.isEmpty {
                    Text(summary)
                        .font(OpenPawTheme.Machine.body)
                        .foregroundStyle(OpenPawTheme.textSecondary)
                }

                if let command = row.command, !command.isEmpty {
                    CodeBlock(text: command, language: .shell, showsLineNumbers: false, firstLine: 1)
                }

                status

                if !row.paths.isEmpty {
                    paths
                }

                if !row.output.isEmpty {
                    output
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: OpenPawTheme.Space.small) {
            Text(row.tool)
                .font(OpenPawTheme.Machine.headline)
                .foregroundStyle(OpenPawTheme.textPrimary)
            if let risk = row.risk {
                RiskChip(risk: risk, style: .inline)
            }
            Spacer(minLength: 0)
            Text(ChatFormat.clock(row.timestamp))
                .font(OpenPawTheme.Machine.codeSmall)
                .foregroundStyle(OpenPawTheme.textTertiary)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch row.status {
        case .running:
            WorkingIndicator(label: "running")
        case .succeeded(let exitCode, let durationMS):
            HStack(spacing: OpenPawTheme.Space.small) {
                Image(systemName: exitCode == 0 || exitCode == nil ? "checkmark" : "exclamationmark.triangle")
                    .imageScale(.small)
                Text(exitCode.map { "exit \($0)" } ?? "finished")
                    .font(OpenPawTheme.Machine.body)
                if let durationMS {
                    Text("·").microLabel()
                    Text(ChatFormat.duration(ms: durationMS))
                        .font(OpenPawTheme.Machine.codeSmall)
                        .foregroundStyle(OpenPawTheme.textTertiary)
                }
            }
            .foregroundStyle(exitCode == 0 || exitCode == nil ? OpenPawTheme.ok : OpenPawTheme.warn)
        case .failed(let error, let exitCode):
            HStack(alignment: .top, spacing: OpenPawTheme.Space.small) {
                Image(systemName: "xmark.octagon.fill")
                    .imageScale(.small)
                VStack(alignment: .leading, spacing: OpenPawTheme.Space.hair) {
                    Text(exitCode.map { "failed · exit \($0)" } ?? "failed")
                        .font(OpenPawTheme.Machine.headline)
                    Text(error)
                        .font(OpenPawTheme.Machine.body)
                        .textSelection(.enabled)
                }
            }
            .foregroundStyle(OpenPawTheme.bad)
        }
    }

    private var paths: some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
            Text("paths").microLabel()
            ForEach(row.paths, id: \.self) { path in
                Button {
                    onOpenFile(path)
                } label: {
                    HStack(spacing: OpenPawTheme.Space.tight) {
                        Image(systemName: "doc.text")
                            .imageScale(.small)
                        Text(path)
                            .font(OpenPawTheme.Machine.code)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .foregroundStyle(OpenPawTheme.textSecondary)
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(path)")
            }
        }
    }

    private var output: some View {
        let capped = ChatFormat.head(row.output, lines: Self.outputPreviewLines)
        let isCapped = capped.total > Self.outputPreviewLines
        return VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
            Text("output").microLabel()

            CodeBlock(
                text: showsAllOutput ? row.output : capped.text,
                language: .shell,
                showsLineNumbers: false,
                firstLine: 1
            )

            if isCapped {
                Button {
                    showsAllOutput.toggle()
                } label: {
                    Label(
                        showsAllOutput
                            ? "Show first \(Self.outputPreviewLines) lines"
                            : "Show all output · \(capped.total) lines",
                        systemImage: showsAllOutput ? "chevron.up" : "chevron.down"
                    )
                    .font(OpenPawTheme.Machine.label)
                    .textCase(.uppercase)
                    .tracking(0.9)
                    .foregroundStyle(OpenPawTheme.textSecondary)
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if row.outputTruncated {
                Text("Truncated — full output is in the terminal")
                    .microLabel(OpenPawTheme.warn)
            }
        }
    }
}

// MARK: - Plan

/// The agent's own checklist. It is updated repeatedly under one plan id, so this card mutates in place and adds
/// no insertion animation: a plan that animated on every update would flicker its way through a long task.
public struct PlanCard: View {
    public let row: PlanRow

    public init(row: PlanRow) {
        self.row = row
    }

    private var done: Int { row.steps.filter { $0.status == .completed }.count }

    public var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                HStack(alignment: .firstTextBaseline, spacing: OpenPawTheme.Space.small) {
                    Text("plan").microLabel()
                    Spacer(minLength: 0)
                    Text("\(done) of \(row.steps.count) done").microLabel(OpenPawTheme.textSecondary)
                }

                if let title = row.title, !title.isEmpty {
                    Text(title)
                        .font(OpenPawTheme.Machine.headline)
                        .foregroundStyle(OpenPawTheme.textPrimary)
                }

                VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
                    ForEach(row.steps) { step in
                        stepRow(step)
                    }
                }
            }
        }
    }

    private func stepRow(_ step: PlanStep) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: OpenPawTheme.Space.small) {
            Image(systemName: Self.glyph(for: step.status))
                .imageScale(.small)
                .foregroundStyle(Self.tint(for: step.status))
            Text(step.title)
                .font(OpenPawTheme.Machine.body)
                .foregroundStyle(
                    step.status == .completed || step.status == .cancelled
                        ? OpenPawTheme.textTertiary
                        : OpenPawTheme.textPrimary
                )
                .strikethrough(step.status == .completed, color: OpenPawTheme.textTertiary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Self.word(for: step.status)): \(step.title)")
    }

    static func glyph(for status: PlanStepStatus) -> String {
        switch status {
        case .pending: "circle"
        case .inProgress: "circle.inset.filled"
        case .completed: "checkmark.circle.fill"
        case .cancelled: "xmark.circle"
        }
    }

    static func tint(for status: PlanStepStatus) -> Color {
        switch status {
        case .pending: OpenPawTheme.textTertiary
        case .inProgress: OpenPawTheme.warn
        case .completed: OpenPawTheme.ok
        case .cancelled: OpenPawTheme.textTertiary
        }
    }

    static func word(for status: PlanStepStatus) -> String {
        switch status {
        case .pending: "pending"
        case .inProgress: "in progress"
        case .completed: "completed"
        case .cancelled: "cancelled"
        }
    }
}

// MARK: - Permission

/// A permission request as it appears *in history*.
///
/// This card carries no approve control, by construction and not by disabling one. A decision can only be taken in
/// the approval sheet, because that is the one surface that can hold the risk gate: an item whose risk requires
/// detail expansion must have its full command revealed and acknowledged first. So the card's only control opens
/// that sheet, and once the request is settled it stops being a prompt at all.
public struct PermissionCard: View {
    public let row: PermissionRow
    public let onApprove: (String) -> Void

    public init(row: PermissionRow, onApprove: @escaping (String) -> Void) {
        self.row = row
        self.onApprove = onApprove
    }

    public var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                HStack(alignment: .firstTextBaseline, spacing: OpenPawTheme.Space.small) {
                    Text(row.isSettled ? "decision" : "permission").microLabel()
                    RiskChip(risk: row.request.risk, style: .inline)
                    Spacer(minLength: 0)
                    Text(ChatFormat.clock(row.timestamp))
                        .font(OpenPawTheme.Machine.codeSmall)
                        .foregroundStyle(OpenPawTheme.textTertiary)
                }

                Text(row.request.summary)
                    .font(OpenPawTheme.Machine.headline)
                    .foregroundStyle(OpenPawTheme.textPrimary)

                if let command = row.request.command, !command.isEmpty {
                    Text(ChatFormat.oneLine(command, limit: 120))
                        .font(OpenPawTheme.Machine.code)
                        .foregroundStyle(OpenPawTheme.textSecondary)
                        .lineLimit(1)
                        .padding(OpenPawTheme.Space.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(OpenPawTheme.well)
                }

                if let settled = row.settledDescription {
                    settledLine(settled)
                } else {
                    reviewControl
                }
            }
        }
    }

    private func settledLine(_ text: String) -> some View {
        HStack(spacing: OpenPawTheme.Space.small) {
            Image(systemName: row.decision?.isApproval == true ? "checkmark.seal.fill" : "nosign")
                .imageScale(.small)
            Text(text)
                .font(OpenPawTheme.Machine.body)
            Spacer(minLength: 0)
        }
        .foregroundStyle(row.decision?.isApproval == true ? OpenPawTheme.ok : OpenPawTheme.textSecondary)
        .frame(minHeight: 32)
    }

    private var reviewControl: some View {
        Button {
            onApprove(row.request.requestID)
        } label: {
            Label("Review request", systemImage: "chevron.right.circle")
                .font(OpenPawTheme.Machine.headline)
                .foregroundStyle(OpenPawTheme.textPrimary)
                .padding(.horizontal, OpenPawTheme.Space.medium)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(Rectangle().strokeBorder(OpenPawTheme.lineStrong, lineWidth: OpenPawTheme.hairline * 3))
        .accessibilityLabel(
            "Review \(OpenPawTheme.label(for: row.request.risk.riskClass)) request: \(row.request.summary)"
        )
    }
}

// MARK: - Question

/// A question the agent asked. Questions carry no risk class, so unlike a permission they can be answered from
/// the row: the gate this product exists for is about commands, not about which option you prefer.
@MainActor
public struct QuestionCard: View {
    public let row: QuestionRow
    public let model: OpenPawModel

    @State private var freeText = ""
    @State private var isSending = false

    public init(row: QuestionRow, model: OpenPawModel) {
        self.row = row
        self.model = model
    }

    /// The inbox item that still wants an answer, if the host has given us one to act on.
    private var pending: InboxItem? {
        model.pendingInbox.first { $0.requestID == row.question.requestID }
    }

    public var body: some View {
        HumanPanel {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                Text("question").microLabel(OpenPawTheme.textSecondary)

                Text(row.question.question)
                    .font(OpenPawTheme.Human.prose)
                    .foregroundStyle(OpenPawTheme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let answer = row.answer {
                    answered(answer)
                } else if let item = pending {
                    choices(item)
                } else {
                    Text("waiting · answer in the terminal").microLabel(OpenPawTheme.textSecondary)
                }
            }
        }
    }

    private func answered(_ answer: String) -> some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
            Text("answer").microLabel(OpenPawTheme.textSecondary)
            Text(answer)
                .font(OpenPawTheme.Human.proseTight)
                .foregroundStyle(OpenPawTheme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func choices(_ item: InboxItem) -> some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
            ForEach(row.question.choices, id: \.self) { choice in
                Button {
                    send(answer: choice, item: item)
                } label: {
                    Text(choice)
                        .font(OpenPawTheme.Human.proseTight)
                        .foregroundStyle(OpenPawTheme.textPrimary)
                        .padding(.horizontal, OpenPawTheme.Space.medium)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isSending)
                .overlay(
                    RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card)
                        .strokeBorder(OpenPawTheme.lineStrong, lineWidth: OpenPawTheme.hairline * 3)
                )
            }

            if row.question.allowsFreeText {
                HStack(spacing: OpenPawTheme.Space.small) {
                    TextField("Type an answer", text: $freeText)
                        .textFieldStyle(.plain)
                        .font(OpenPawTheme.Human.proseTight)
                        .foregroundStyle(OpenPawTheme.textPrimary)
                        .padding(.horizontal, OpenPawTheme.Space.small)
                        .frame(minHeight: 44)
                        .background(OpenPawTheme.well, in: RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card))

                    Button {
                        send(answer: freeText, item: item)
                    } label: {
                        Text("Send answer")
                            .font(OpenPawTheme.Machine.label)
                            .textCase(.uppercase)
                            .tracking(0.9)
                            .foregroundStyle(OpenPawTheme.textPrimary)
                            .padding(.horizontal, OpenPawTheme.Space.medium)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isSending || freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .overlay(
                        RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card)
                            .strokeBorder(OpenPawTheme.lineStrong, lineWidth: OpenPawTheme.hairline * 3)
                    )
                }
            }
        }
    }

    private func send(answer: String, item: InboxItem) {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        isSending = true
        Task {
            await model.resolve(item, action: .answer, answer: text)
            freeText = ""
            isSending = false
        }
    }
}

// MARK: - File edit

/// A file the agent changed, with as much of the patch as fits inline.
public struct FileEditCard: View {
    /// Eight lines shows the shape of a small edit. Anything larger belongs in the diff viewer, which can scroll.
    static let diffPreviewLines = 8

    public let row: FileEditRow
    public let onOpenFile: (String) -> Void

    public init(row: FileEditRow, onOpenFile: @escaping (String) -> Void) {
        self.row = row
        self.onOpenFile = onOpenFile
    }

    private var diff: MiniDiff? {
        guard let patch = row.unifiedDiff, !patch.isEmpty else { return nil }
        let parsed = MiniDiff.parse(patch)
        return parsed.isEmpty ? nil : parsed
    }

    public var body: some View {
        Panel(padding: OpenPawTheme.Space.medium) {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
                Button {
                    onOpenFile(row.path)
                } label: {
                    header
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityDescription)

                if let diff {
                    miniDiff(diff)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: OpenPawTheme.Space.small) {
            Image(systemName: Self.glyph(for: row.change))
                .imageScale(.small)
                .foregroundStyle(Self.tint(for: row.change))
            Text(row.path)
                .font(OpenPawTheme.Machine.code)
                .foregroundStyle(OpenPawTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: OpenPawTheme.Space.small)
            if let additions = row.additions, additions > 0 {
                Text("+\(additions)")
                    .font(OpenPawTheme.Machine.codeSmall)
                    .foregroundStyle(OpenPawTheme.diffAddedText)
            }
            if let deletions = row.deletions, deletions > 0 {
                Text("-\(deletions)")
                    .font(OpenPawTheme.Machine.codeSmall)
                    .foregroundStyle(OpenPawTheme.diffRemovedText)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private func miniDiff(_ diff: MiniDiff) -> some View {
        let shown = Array(diff.lines.prefix(Self.diffPreviewLines))
        let hidden = diff.lines.count - shown.count
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(shown) { line in
                diffLine(line)
            }
            if hidden > 0 {
                Text("\(hidden) more \(hidden == 1 ? "line" : "lines") · \(diff.hunkCount) "
                    + "\(diff.hunkCount == 1 ? "hunk" : "hunks")")
                    .microLabel()
                    .padding(.top, OpenPawTheme.Space.tight)
            }
            Button {
                onOpenFile(row.path)
            } label: {
                Label("Open full diff", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(OpenPawTheme.Machine.label)
                    .textCase(.uppercase)
                    .tracking(0.9)
                    .foregroundStyle(OpenPawTheme.textSecondary)
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, OpenPawTheme.Space.tight)
    }

    private func diffLine(_ line: MiniDiffLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: OpenPawTheme.Space.small) {
            Text(line.oldLine.map(String.init) ?? "")
                .frame(minWidth: OpenPawTheme.Space.xxl, alignment: .trailing)
            Text(line.newLine.map(String.init) ?? "")
                .frame(minWidth: OpenPawTheme.Space.xxl, alignment: .trailing)
            Text(Self.marker(for: line.kind) + line.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(OpenPawTheme.Machine.codeSmall)
        .foregroundStyle(Self.tint(for: line.kind))
        .padding(.vertical, OpenPawTheme.Space.hair)
        .padding(.horizontal, OpenPawTheme.Space.tight)
        .background(Self.fill(for: line.kind))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(line.kind.rawValue) line \(line.newLine ?? line.oldLine ?? 0): \(line.text)")
    }

    private var accessibilityDescription: String {
        var parts = ["\(row.change.rawValue) \(row.path)"]
        if let additions = row.additions { parts.append("\(additions) added") }
        if let deletions = row.deletions { parts.append("\(deletions) removed") }
        parts.append("opens the file")
        return parts.joined(separator: ", ")
    }

    static func marker(for kind: MiniDiffLine.Kind) -> String {
        switch kind {
        case .added: "+"
        case .removed: "-"
        case .context: " "
        }
    }

    static func tint(for kind: MiniDiffLine.Kind) -> Color {
        switch kind {
        case .added: OpenPawTheme.diffAddedText
        case .removed: OpenPawTheme.diffRemovedText
        case .context: OpenPawTheme.textSecondary
        }
    }

    static func fill(for kind: MiniDiffLine.Kind) -> Color {
        switch kind {
        case .added: OpenPawTheme.diffAddedFill
        case .removed: OpenPawTheme.diffRemovedFill
        case .context: Color.clear
        }
    }

    static func glyph(for change: FileChangeKind) -> String {
        switch change {
        case .read: "eye"
        case .created: "plus.square"
        case .modified: "square.and.pencil"
        case .deleted: "trash"
        }
    }

    static func tint(for change: FileChangeKind) -> Color {
        switch change {
        case .read: OpenPawTheme.textTertiary
        case .created: OpenPawTheme.diffAddedText
        case .modified: OpenPawTheme.textSecondary
        case .deleted: OpenPawTheme.diffRemovedText
        }
    }
}

// MARK: - Lifecycle

extension LifecycleRow {
    /// `agent completed · exit 0`. Words first, because the colour is the smallest part of this, and a lifecycle
    /// row is nothing but its label — there is no other content to fall back on.
    public var summaryLabel: String {
        let head: String =
            switch kind {
            case .agentStarted: "agent started"
            case .agentCompleted: "agent completed"
            case .agentFailed: "agent failed"
            default: kind.rawValue.replacingOccurrences(of: ".", with: " ")
            }
        var parts: [String] = [head]
        if let exitCode { parts.append("exit \(exitCode)") }
        if let reason, !reason.isEmpty { parts.append(ChatFormat.oneLine(reason, limit: 60)) }
        return parts.joined(separator: " · ")
    }
}

/// A session boundary. It is a rule, not a card: the agent starting or exiting is punctuation between turns, and
/// giving it a panel would make it compete with the work either side of it.
public struct LifecycleCard: View {
    public let row: LifecycleRow

    public init(row: LifecycleRow) {
        self.row = row
    }

    public var body: some View {
        HStack(spacing: OpenPawTheme.Space.medium) {
            rule
            Text(row.summaryLabel).microLabel(Self.tint(for: row))
            rule
        }
        .frame(minHeight: 32)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.summaryLabel)
    }

    private var rule: some View {
        Rectangle()
            .fill(OpenPawTheme.line)
            .frame(height: OpenPawTheme.hairline * 3)
    }

    static func tint(for row: LifecycleRow) -> Color {
        switch row.kind {
        case .agentFailed: OpenPawTheme.bad
        case .agentCompleted: (row.exitCode ?? 0) == 0 ? OpenPawTheme.ok : OpenPawTheme.warn
        default: OpenPawTheme.textTertiary
        }
    }
}

// MARK: - Previews

#Preview("Chat cards") {
    let model = PreviewBackend.model()
    return ScrollView {
        LazyVStack(alignment: .leading, spacing: OpenPawTheme.Space.large) {
            ForEach(model.chat(for: PreviewBackend.claudeSessionID)) { item in
                ChatRow(
                    item: item,
                    widestSeq: nil,
                    model: model,
                    onOpenFile: { _ in },
                    onApprove: { _ in }
                )
            }
        }
        .padding(OpenPawTheme.Space.large)
    }
    .background(OpenPawTheme.ink)
}
