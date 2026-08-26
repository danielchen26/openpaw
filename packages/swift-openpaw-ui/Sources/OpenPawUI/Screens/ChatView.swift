import Foundation
import OpenPawProtocol
import OpenPawTerminalCore
import SwiftUI

// MARK: - Context load

/// Where the context window sits relative to the two thresholds that change what a person should do.
///
/// The numbers are not this screen's invention: `InboxProjection.contextWarningPercent` is the point at which the
/// host raises a context warning in the inbox, so a meter that turned amber anywhere else would contradict the
/// notification the user already received.
public enum ContextLoad: String, Sendable, Hashable, CaseIterable {
    /// Plenty of room. Nothing to do.
    case nominal
    /// Compaction is coming. Worth finishing the current thought.
    case warn
    /// Compaction is imminent; the agent is about to forget things.
    case critical

    /// Same threshold the host uses to raise an inbox warning.
    public static let warnPercent = InboxProjection.contextWarningPercent
    /// Above this the window is effectively gone.
    public static let criticalPercent = 95.0

    public init(percent: Double) {
        if percent >= Self.criticalPercent {
            self = .critical
        } else if percent >= Self.warnPercent {
            self = .warn
        } else {
            self = .nominal
        }
    }

    /// Deliberately not the risk ramp: a full context window is a resource state, not a dangerous command.
    public var color: Color {
        switch self {
        case .nominal: OpenPawTheme.textSecondary
        case .warn: OpenPawTheme.warn
        case .critical: OpenPawTheme.bad
        }
    }

    /// The word that carries the meaning when colour does not reach the reader.
    public var word: String {
        switch self {
        case .nominal: "nominal"
        case .warn: "filling up"
        case .critical: "nearly full"
        }
    }
}

// MARK: - Formatting

/// Number and time formatting shared by the chat cards, the header meters and the event log.
///
/// All of it is deterministic and locale-independent on purpose: these are machine-register values that sit in
/// monospaced columns, and a thousands separator that moves between devices would break the column.
enum ChatFormat {

    static func tokens(_ count: UInt64) -> String {
        if count < 1_000 { return "\(count)" }
        if count < 1_000_000 { return String(format: "%.1fk", Double(count) / 1_000) }
        return String(format: "%.2fM", Double(count) / 1_000_000)
    }

    static func duration(ms: UInt64) -> String {
        if ms < 1_000 { return "\(ms) ms" }
        if ms < 60_000 { return String(format: "%.1f s", Double(ms) / 1_000) }
        let seconds = ms / 1_000
        return "\(seconds / 60) m \(seconds % 60) s"
    }

    static func cost(_ usd: Double) -> String {
        if usd > 0, usd < 0.005 { return "<$0.01" }
        return String(format: "$%.2f", usd)
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    /// 24 hour wall clock, fixed width, no locale drift — this sits next to a sequence number.
    static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    /// Collapses a multi-line blob to its first non-empty line, for one-line summaries.
    static func oneLine(_ text: String, limit: Int = 160) -> String {
        let first = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }

    /// Leading `limit` lines plus the true total, so a card can say how much it is holding back.
    static func head(_ text: String, lines limit: Int) -> (text: String, total: Int) {
        var all = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while all.last?.isEmpty == true { all.removeLast() }
        let total = all.count
        guard total > limit else { return (all.joined(separator: "\n"), total) }
        return (all.prefix(limit).joined(separator: "\n"), total)
    }
}

// MARK: - Cell meter

/// A meter drawn as monospaced cells rather than a bar.
///
/// It costs no geometry pass, it scales with Dynamic Type for free, and it sits in the same 14-column rhythm the
/// working indicator uses, so the header reads as one instrument panel instead of three unrelated widgets.
struct CellMeter: View {
    let fraction: Double
    let tint: Color
    var cells: Int = 14

    var body: some View {
        let clamped = max(0, min(1, fraction))
        let filled = Int((clamped * Double(cells)).rounded())
        Text(String(repeating: "█", count: filled) + String(repeating: "░", count: cells - filled))
            .font(OpenPawTheme.Machine.codeSmall)
            .foregroundStyle(tint)
            .accessibilityHidden(true)
    }
}

// MARK: - Session header

/// The instrument panel above the transcript: who is working, on what, and how much runway is left.
@MainActor
struct SessionHeader: View {
    let session: SessionSummary?
    let sessionID: String
    let vitals: SessionVitals
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
            HStack(alignment: .firstTextBaseline, spacing: OpenPawTheme.Space.medium) {
                Text(session?.title ?? sessionID)
                    .font(OpenPawTheme.Human.title)
                    .foregroundStyle(OpenPawTheme.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: OpenPawTheme.Space.small)
                if case .working = vitals.activity {
                    StopButton(action: onStop)
                }
            }

            provenance

            activityLine

            if let percent = vitals.contextPercent {
                contextMeter(percent: percent)
            }

            usageLine

            if let limit = vitals.rateLimitPercent {
                rateLimitMeter(percent: limit)
            }
        }
        .padding(.horizontal, OpenPawTheme.Space.large)
        .padding(.vertical, OpenPawTheme.Space.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OpenPawTheme.panel)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(OpenPawTheme.line)
                .frame(height: OpenPawTheme.hairline)
        }
    }

    /// Agent, working directory and branch: the three facts that tell you which machine you are about to change.
    private var provenance: some View {
        HStack(spacing: OpenPawTheme.Space.small) {
            Text((session?.agent ?? .generic).displayName).microLabel(OpenPawTheme.textSecondary)

            if let cwd = session?.cwd {
                Text("·").microLabel()
                Text(cwd)
                    .font(OpenPawTheme.Machine.codeSmall)
                    .foregroundStyle(OpenPawTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .accessibilityLabel("Working directory \(cwd)")
            }

            if let branch = session?.gitBranch {
                Text("·").microLabel()
                Label(branch, systemImage: "arrow.triangle.branch")
                    .labelStyle(.titleAndIcon)
                    .font(OpenPawTheme.Machine.codeSmall)
                    .foregroundStyle(OpenPawTheme.textTertiary)
                    .lineLimit(1)
                    .accessibilityLabel("Branch \(branch)")
            }
        }
    }

    private var activityLine: some View {
        HStack(spacing: OpenPawTheme.Space.small) {
            switch vitals.activity {
            case .idle:
                Image(systemName: "pause.circle")
                    .foregroundStyle(OpenPawTheme.textTertiary)
                Text("idle").font(OpenPawTheme.Machine.body).foregroundStyle(OpenPawTheme.textSecondary)
            case .working(let tool):
                WorkingIndicator(label: tool.map { "working · \($0)" } ?? "working")
            case .waiting(let reason):
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(OpenPawTheme.warn)
                Text("waiting · \(ChatFormat.oneLine(reason, limit: 60))")
                    .font(OpenPawTheme.Machine.body)
                    .foregroundStyle(OpenPawTheme.warn)
                    .lineLimit(1)
            case .failed(let reason):
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(OpenPawTheme.bad)
                Text(reason.map { "failed · \(ChatFormat.oneLine($0, limit: 60))" } ?? "failed")
                    .font(OpenPawTheme.Machine.body)
                    .foregroundStyle(OpenPawTheme.bad)
                    .lineLimit(1)
            case .completed:
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(OpenPawTheme.ok)
                Text("completed").font(OpenPawTheme.Machine.body).foregroundStyle(OpenPawTheme.ok)
            }
            Spacer(minLength: 0)
            Text("seq \(vitals.lastSeq)")
                .font(OpenPawTheme.Machine.codeSmall)
                .foregroundStyle(OpenPawTheme.textTertiary)
        }
        .imageScale(.small)
    }

    private func contextMeter(percent: Double) -> some View {
        let load = ContextLoad(percent: percent)
        let amount: (used: UInt64, limit: UInt64)? =
            if let used = vitals.contextUsedTokens, let limit = vitals.contextMaxTokens {
                (used, limit)
            } else {
                nil
            }
        return HStack(spacing: OpenPawTheme.Space.small) {
            Text("CONTEXT").microLabel()
            CellMeter(fraction: percent / 100, tint: load.color)
            Text(ChatFormat.percent(percent))
                .font(OpenPawTheme.Machine.body)
                .foregroundStyle(load.color)
            if let amount {
                Text("\(ChatFormat.tokens(amount.used))/\(ChatFormat.tokens(amount.limit))")
                    .font(OpenPawTheme.Machine.codeSmall)
                    .foregroundStyle(OpenPawTheme.textTertiary)
            }
            if load != .nominal {
                Text(load.word)
                    .font(OpenPawTheme.Machine.codeSmall)
                    .foregroundStyle(load.color)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            amount.map {
                "Context window \(ChatFormat.percent(percent)) used, "
                    + "\($0.used) of \($0.limit) tokens, \(load.word)"
            } ?? "Context window \(ChatFormat.percent(percent)) used, \(load.word)"
        )
    }

    private var usageLine: some View {
        HStack(spacing: OpenPawTheme.Space.small) {
            Text("TOKENS").microLabel()
            Text("in \(ChatFormat.tokens(vitals.inputTokens))")
                .font(OpenPawTheme.Machine.codeSmall)
                .foregroundStyle(OpenPawTheme.textSecondary)
            Text("out \(ChatFormat.tokens(vitals.outputTokens))")
                .font(OpenPawTheme.Machine.codeSmall)
                .foregroundStyle(OpenPawTheme.textSecondary)
            if let cost = vitals.costUSD {
                Text("·").microLabel()
                Text(ChatFormat.cost(cost))
                    .font(OpenPawTheme.Machine.codeSmall)
                    .foregroundStyle(OpenPawTheme.textSecondary)
                    .accessibilityLabel("Cost \(ChatFormat.cost(cost))")
            }
            Spacer(minLength: 0)
        }
    }

    private func rateLimitMeter(percent: Double) -> some View {
        let isTight = percent >= InboxProjection.rateLimitWarningPercent
        let tint = isTight ? OpenPawTheme.warn : OpenPawTheme.textSecondary
        return HStack(spacing: OpenPawTheme.Space.small) {
            Text("RATE LIMIT").microLabel()
            CellMeter(fraction: percent / 100, tint: tint)
            Text(ChatFormat.percent(percent))
                .font(OpenPawTheme.Machine.body)
                .foregroundStyle(tint)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rate limit \(ChatFormat.percent(percent)) used")
    }
}

/// Interrupting the agent is destructive enough to name plainly and small enough to keep out of a menu.
struct StopButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Stop", systemImage: "stop.fill")
                .labelStyle(.titleAndIcon)
                .font(OpenPawTheme.Machine.label)
                .textCase(.uppercase)
                .tracking(0.9)
                .foregroundStyle(OpenPawTheme.bad)
                .padding(.horizontal, OpenPawTheme.Space.small)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(
            RoundedRectangle(cornerRadius: OpenPawTheme.Radius.machine, style: .continuous)
                .strokeBorder(OpenPawTheme.bad.opacity(0.6), lineWidth: OpenPawTheme.hairline * 3)
        )
        .accessibilityLabel("Stop the agent")
    }
}

// MARK: - Chat view

/// Chat View is a projection of the agent's own transcript. Every row here came out of the normalized event
/// stream, which is why each one carries the sequence number it can be resumed from: nothing on this screen is
/// scraped from the terminal's ANSI output, and nothing is generated by a second model.
@MainActor
public struct ChatView: View {
    private static let bottomAnchor = "openpaw.chat.bottom"

    public let model: OpenPawModel
    public let settings: OpenPawSettings
    public let sessionID: String
    /// A path the reader asked to see — a file edit row, or a path a tool touched.
    public let onOpenFile: (String) -> Void
    /// A permission request id the reader asked to decide. The approval sheet is the only place a decision is
    /// taken, because it is the only place the risk gate can be enforced.
    public let onApprove: (String) -> Void

    @State private var isAtBottom = true
    @State private var seenRows = 0

    public init(
        model: OpenPawModel,
        settings: OpenPawSettings = OpenPawSettings(),
        sessionID: String,
        onOpenFile: @escaping (String) -> Void,
        onApprove: @escaping (String) -> Void
    ) {
        self.model = model
        self.settings = settings
        self.sessionID = sessionID
        self.onOpenFile = onOpenFile
        self.onApprove = onApprove
    }

    private var rows: [ChatItem] { model.chat(for: sessionID) }
    private var vitals: SessionVitals { model.vitals(for: sessionID) }

    public var body: some View {
        let rows = self.rows
        let pending = max(0, rows.count - seenRows)

        return VStack(spacing: 0) {
            SessionHeader(
                session: model.session(sessionID),
                sessionID: sessionID,
                vitals: vitals,
                onStop: { Task { await stopAgent() } }
            )

            if rows.isEmpty {
                EmptyStateView(
                    glyph: "text.append",
                    title: "No transcript yet",
                    message: "Start the agent in this session's terminal. Its turns, tool calls and file edits "
                        + "appear here as they happen, each tagged with the sequence number it resumes from."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                transcript(rows: rows, pending: pending)
            }

            ComposerView(
                engine: model.selectedDictationEngine(for: settings),
                settings: settings,
                unavailableMessage: model.dictationUnavailableMessage(for: settings),
                supportsAgentAttachments: model.canSendAgentAttachments()
            ) { action, attachments in
                await model.commitVoice(action, attachments: attachments)
            }
        }
        .background(OpenPawTheme.ink)
    }

    private func transcript(rows: [ChatItem], pending: Int) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: OpenPawTheme.Space.large) {
                    ForEach(rows) { item in
                        ChatRow(
                            item: item,
                            widestSeq: rows.last?.seq,
                            model: model,
                            onOpenFile: onOpenFile,
                            onApprove: onApprove
                        )
                        .id(item.id)
                    }

                    // Tracks whether the reader is parked at the newest row. Auto-scrolling someone who has
                    // deliberately scrolled back is the fastest way to lose their place in a long run.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                        .onAppear {
                            isAtBottom = true
                            seenRows = rows.count
                        }
                        .onDisappear { isAtBottom = false }
                }
                .padding(OpenPawTheme.Space.large)
            }
            .overlay(alignment: .bottom) {
                if pending > 0 {
                    JumpToNewestPill(count: pending) {
                        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                        seenRows = rows.count
                        isAtBottom = true
                    }
                    .padding(.bottom, OpenPawTheme.Space.large)
                }
            }
            .onAppear {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                seenRows = rows.count
            }
            .onChange(of: rows.count) { _, newCount in
                guard isAtBottom else { return }
                seenRows = newCount
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        }
    }

    /// Stop takes the structured path when the host has offered one, and falls back to the interrupt a person at
    /// the keyboard would send. The terminal is authoritative for execution, so it is always a valid last word.
    private func stopAgent() async {
        if let item = model.pendingInbox.first(where: {
            $0.sessionID.rawValue == sessionID && $0.actions.contains(.stop)
        }) {
            await model.resolve(item, action: .stop)
            return
        }
        guard let terminal = model.terminal else { return }
        do {
            try await terminal.send(chord: KeyChord(.text("c"), modifiers: .control), applicationCursorKeys: false)
        } catch {
            model.present(error, while: "stopping the agent")
        }
    }
}

/// One transcript row: the sequence spine, then the card for whatever kind of row it is.
@MainActor
struct ChatRow: View {
    let item: ChatItem
    let widestSeq: UInt64?
    let model: OpenPawModel
    let onOpenFile: (String) -> Void
    let onApprove: (String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: OpenPawTheme.Space.medium) {
            SeqSpine(seq: item.seq, widestSeq: widestSeq)
            card
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var card: some View {
        switch item {
        case .prose(let row):
            ProseCard(row: row)
        case .thinking(let row):
            ThinkingCard(row: row)
        case .tool(let row):
            ToolCard(row: row, onOpenFile: onOpenFile)
        case .plan(let row):
            PlanCard(row: row)
        case .permission(let row):
            PermissionCard(row: row, onApprove: onApprove)
        case .question(let row):
            QuestionCard(row: row, model: model)
        case .fileEdit(let row):
            FileEditCard(row: row, onOpenFile: onOpenFile)
        case .lifecycle(let row):
            LifecycleCard(row: row)
        }
    }
}

/// Shown only when the reader has scrolled away from the newest row, and it says how much has arrived since.
public struct ChatComposerConfiguration {
    public let settings: OpenPawSettings
    public let initialLocaleID: String
    public let initialDestination: VoiceDestination

    @MainActor public static func make(model: OpenPawModel, settings: OpenPawSettings) -> Self {
        let restored = ComposerDictationPreferences.restored(localeID: settings.dictationLocaleID, mode: settings.dictationMode)
        return Self(settings: settings, initialLocaleID: restored.localeID, initialDestination: restored.destination)
    }
}

struct JumpToNewestPill: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: OpenPawTheme.Space.small) {
                Image(systemName: "arrow.down")
                    .imageScale(.small)
                Text("Jump to newest")
                    .font(OpenPawTheme.Machine.headline)
                Text("\(count)")
                    .font(OpenPawTheme.Machine.label)
                    .foregroundStyle(OpenPawTheme.ink)
                    .padding(.horizontal, OpenPawTheme.Space.small)
                    .padding(.vertical, OpenPawTheme.Space.hair)
                    .background(OpenPawTheme.textPrimary, in: Capsule())
            }
            .foregroundStyle(OpenPawTheme.textPrimary)
            .padding(.horizontal, OpenPawTheme.Space.large)
            .frame(minHeight: 44)
            .background(OpenPawTheme.panel, in: Capsule())
            .overlay(Capsule().strokeBorder(OpenPawTheme.lineStrong, lineWidth: OpenPawTheme.hairline * 3))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Jump to newest, \(count) new \(count == 1 ? "row" : "rows")")
    }
}

// MARK: - Previews

#Preview("Chat · populated") {
    let model = PreviewBackend.model()
    return ChatView(
        model: model,
        sessionID: PreviewBackend.claudeSessionID,
        onOpenFile: { _ in },
        onApprove: { _ in }
    )
}

/// The only preview in which the activity is `.working`, so it is the only one that renders the working
/// indicator's scanline and the `Stop` control. Both belong in the snapshot set for that reason.
#Preview("Chat · working") {
    let model = PreviewBackend.model()
    return ChatView(
        model: model,
        sessionID: PreviewBackend.workingSessionID,
        onOpenFile: { _ in },
        onApprove: { _ in }
    )
}

#Preview("Chat · no transcript") {
    let model = PreviewBackend.model(.empty)
    return ChatView(
        model: model,
        sessionID: PreviewBackend.claudeSessionID,
        onOpenFile: { _ in },
        onApprove: { _ in }
    )
}
