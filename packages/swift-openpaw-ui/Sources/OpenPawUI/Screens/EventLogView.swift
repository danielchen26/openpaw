import Foundation
import OpenPawProtocol
import SwiftUI

// MARK: - Summaries

/// One line per event, dense enough to scan a hundred of them and specific enough to debug an adapter with.
///
/// Every branch is exhaustive over `Body`, including `.unsupported`: an event this build predates still has a
/// sequence number, a type string and a payload, and hiding it would make the log lie about what the host sent.
enum EventSummary {

    static func line(for event: Event) -> String {
        switch event.body {
        case .agentStarted(let life):
            return life.title ?? life.reason ?? "session opened"
        case .agentWorking(let life):
            return life.reason ?? "working"
        case .agentCompleted(let life):
            return join(life.exitCode.map { "exit \($0)" }, life.reason)
        case .agentFailed(let life):
            return life.reason ?? "failed"

        case .turnStarted(let turn):
            return join(turn.role.rawValue, turn.text.map { ChatFormat.oneLine($0) } ?? turn.turnID)
        case .turnDelta(let delta):
            return join(delta.kind.rawValue, "+\(delta.delta.count) chars", delta.turnID)
        case .turnCompleted(let turn):
            return join(turn.role.rawValue, ChatFormat.oneLine(turn.text))

        case .toolStarted(let tool):
            return join(tool.tool, tool.command ?? tool.summary ?? tool.paths.first)
        case .toolOutput(let chunk):
            return join(
                chunk.stream.rawValue,
                "+\(chunk.chunk.utf8.count) B",
                chunk.truncated ? "truncated" : nil
            )
        case .toolCompleted(let done):
            return join(
                done.exitCode.map { "exit \($0)" } ?? "finished",
                done.durationMs.map { ChatFormat.duration(ms: $0) },
                done.summary.map { ChatFormat.oneLine($0, limit: 60) }
            )
        case .toolFailed(let failure):
            return join(failure.exitCode.map { "exit \($0)" }, ChatFormat.oneLine(failure.error))

        case .permissionRequested(let request):
            return join(
                OpenPawTheme.label(for: request.risk.riskClass),
                request.tool,
                ChatFormat.oneLine(request.summary, limit: 80)
            )
        case .permissionResolved(let resolution):
            return join(resolution.decision.rawValue, "by \(resolution.decidedBy.rawValue)")
        case .questionRequested(let question):
            return ChatFormat.oneLine(question.question)
        case .questionAnswered(let answered):
            return ChatFormat.oneLine(answered.answer)

        case .planCreated(let plan), .planUpdated(let plan):
            return join(
                "\(plan.completedCount)/\(plan.steps.count) done",
                plan.title.map { ChatFormat.oneLine($0, limit: 60) } ?? plan.planID
            )

        case .fileRead(let change), .fileCreated(let change),
             .fileModified(let change), .fileDeleted(let change):
            return join(
                change.path,
                change.additions.map { "+\($0)" },
                change.deletions.map { "-\($0)" },
                change.unifiedDiff == nil ? nil : "patch attached"
            )

        case .usageUpdated(let usage):
            return join(
                "in \(ChatFormat.tokens(usage.inputTokens))",
                "out \(ChatFormat.tokens(usage.outputTokens))",
                usage.costUSD.map { ChatFormat.cost($0) },
                usage.rateLimitPercent.map { "rate \(ChatFormat.percent($0))" }
            )
        case .contextUpdated(let context):
            return join(
                ChatFormat.percent(context.percentUsed),
                "\(ChatFormat.tokens(context.usedTokens))/\(ChatFormat.tokens(context.maxTokens))"
            )

        case .unsupported(let type, let payload):
            let fields = payload.objectValue?.count
            return join("this build has no reader for \(type)", fields.map { "\($0) fields" })
        }
    }

    /// Whether this event is worth marking as a problem in the log. Failures earn colour; nothing else does.
    static func isFailure(_ event: Event) -> Bool {
        switch event.body {
        case .agentFailed, .toolFailed: true
        default: false
        }
    }

    private static func join(_ parts: String?...) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Pretty-prints the `payload` object of an event exactly as it arrived on the wire.
///
/// Round-tripping through the protocol coder rather than reflecting over the Swift value is deliberate: what a
/// diagnostics screen has to show is the JSON the host actually sent, snake_case keys and RFC 3339 timestamps
/// included, not a Swift-shaped paraphrase of it.
enum EventPayload {

    static func json(for event: Event) -> String {
        guard let encoded = try? OpenPawCoding.prettyEncoder.encode(event) else {
            return "{}"
        }
        guard
            let tree = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any],
            let payload = tree["payload"]
        else {
            return String(decoding: encoded, as: UTF8.self)
        }
        guard
            JSONSerialization.isValidJSONObject(payload),
            let rendered = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
        else {
            return String(describing: payload)
        }
        return String(decoding: rendered, as: UTF8.self)
    }
}

// MARK: - Event log

/// The normalized event stream, unedited.
///
/// Chat View is an interpretation; this is the record it was built from. It exists so that "the protocol is real"
/// is something a person can check rather than something the app asserts: every row shows the sequence number the
/// stream can be resumed from, the wire `type`, and — one tap away — the exact payload JSON.
@MainActor
public struct EventLogView: View {
    public let model: OpenPawModel
    public let sessionID: String

    /// Empty means every type. Filtering to nothing would be a screen with no purpose, so "all" is the identity.
    @State private var selectedTypes: Set<EventType> = []
    @State private var expanded: Set<String> = []

    public init(model: OpenPawModel, sessionID: String) {
        self.model = model
        self.sessionID = sessionID
    }

    private var events: [Event] { model.events(for: sessionID).sorted { $0.seq < $1.seq } }

    public var body: some View {
        let all = events
        let counts = EventLogFilter.counts(of: all)
        let shown = EventLogFilter.apply(all, types: selectedTypes)

        return VStack(spacing: 0) {
            header(total: all.count, shown: shown.count, counts: counts, lastSeq: all.last?.seq)

            if all.isEmpty {
                EmptyStateView(
                    glyph: "waveform.path.ecg",
                    title: "No events yet",
                    message: "This session has not emitted anything. Once the agent runs, every normalized event "
                        + "lands here with its sequence number and its payload."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if shown.isEmpty {
                EmptyStateView(
                    glyph: "line.3.horizontal.decrease.circle",
                    title: "No events match the filter",
                    message: "This session emitted \(all.count) events, none of the selected types. "
                        + "Clear the filter to see all of them.",
                    actionTitle: "Show all types",
                    action: { selectedTypes = [] }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list(shown, widestSeq: all.last?.seq)
            }
        }
        .background(OpenPawTheme.ink)
    }

    // MARK: Header

    private func header(
        total: Int, shown: Int, counts: [EventType: Int], lastSeq: UInt64?
    ) -> some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
            HStack(alignment: .firstTextBaseline, spacing: OpenPawTheme.Space.small) {
                Text("event log").microLabel(OpenPawTheme.textSecondary)
                Spacer(minLength: 0)
                filterMenu(counts: counts)
            }

            HStack(spacing: OpenPawTheme.Space.small) {
                Text(selectedTypes.isEmpty ? "\(total) events" : "\(shown) of \(total) events")
                    .font(OpenPawTheme.Machine.body)
                    .foregroundStyle(OpenPawTheme.textPrimary)
                Text("·").microLabel()
                Text("\(counts.count) \(counts.count == 1 ? "type" : "types")")
                    .font(OpenPawTheme.Machine.codeSmall)
                    .foregroundStyle(OpenPawTheme.textTertiary)
                if let lastSeq {
                    Text("·").microLabel()
                    Text("resume after seq \(lastSeq)")
                        .font(OpenPawTheme.Machine.codeSmall)
                        .foregroundStyle(OpenPawTheme.textTertiary)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, OpenPawTheme.Space.large)
        .padding(.vertical, OpenPawTheme.Space.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OpenPawTheme.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(OpenPawTheme.line).frame(height: OpenPawTheme.hairline)
        }
    }

    /// Only the types this session actually emitted, with their counts. Listing all twenty-three every time would
    /// make the reader hunt for the four that are present.
    private func filterMenu(counts: [EventType: Int]) -> some View {
        Menu {
            Button("Show all types") { selectedTypes = [] }
            Divider()
            ForEach(counts.keys.sorted { $0.rawValue < $1.rawValue }, id: \.self) { type in
                Toggle(isOn: binding(for: type)) {
                    Text("\(type.rawValue)  \(counts[type] ?? 0)")
                }
            }
        } label: {
            HStack(spacing: OpenPawTheme.Space.tight) {
                Image(systemName: selectedTypes.isEmpty
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill")
                    .imageScale(.medium)
                Text(selectedTypes.isEmpty ? "all types" : "\(selectedTypes.count) selected")
                    .font(OpenPawTheme.Machine.label)
                    .textCase(.uppercase)
                    .tracking(0.9)
            }
            .foregroundStyle(OpenPawTheme.textSecondary)
            .padding(.horizontal, OpenPawTheme.Space.small)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(
            selectedTypes.isEmpty
                ? "Filter by event type, showing all types"
                : "Filter by event type, \(selectedTypes.count) selected"
        )
    }

    private func binding(for type: EventType) -> Binding<Bool> {
        Binding(
            get: { selectedTypes.contains(type) },
            set: { isOn in
                if isOn {
                    selectedTypes.insert(type)
                } else {
                    selectedTypes.remove(type)
                }
            }
        )
    }

    // MARK: List

    private func list(_ shown: [Event], widestSeq: UInt64?) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(shown) { event in
                    EventLogRow(
                        event: event,
                        widestSeq: widestSeq,
                        isExpanded: expanded.contains(event.eventID.rawValue),
                        toggle: { toggle(event) }
                    )
                    Rectangle()
                        .fill(OpenPawTheme.line)
                        .frame(height: OpenPawTheme.hairline)
                }
            }
            .padding(.vertical, OpenPawTheme.Space.small)
        }
    }

    private func toggle(_ event: Event) {
        let key = event.eventID.rawValue
        if expanded.contains(key) {
            expanded.remove(key)
        } else {
            expanded.insert(key)
        }
    }
}

/// The log's selection rules, kept off the view so they are plain functions over a stream rather than something
/// that can only run while a screen is on screen.
enum EventLogFilter {

    /// How many of each type this stream carried. Only the types actually present are offered in the filter menu.
    static func counts(of events: [Event]) -> [EventType: Int] {
        var counts: [EventType: Int] = [:]
        for event in events {
            guard let kind = event.body.kind else { continue }
            counts[kind, default: 0] += 1
        }
        return counts
    }

    /// An empty selection means no filter. Unsupported events have no `EventType`, so they survive a filter only
    /// when nothing is selected — there is no type a reader could tick to ask for them.
    static func apply(_ events: [Event], types: Set<EventType>) -> [Event] {
        guard !types.isEmpty else { return events }
        return events.filter { event in
            guard let kind = event.body.kind else { return false }
            return types.contains(kind)
        }
    }
}

/// One raw event: spine, wire type, one-line summary, and the payload behind a disclosure.
struct EventLogRow: View {
    let event: Event
    let widestSeq: UInt64?
    let isExpanded: Bool
    let toggle: () -> Void

    private var isUnsupported: Bool { event.body.kind == nil }

    private var tint: Color {
        if EventSummary.isFailure(event) { return OpenPawTheme.bad }
        if isUnsupported { return OpenPawTheme.warn }
        return OpenPawTheme.textPrimary
    }

    var body: some View {
        HStack(alignment: .top, spacing: OpenPawTheme.Space.medium) {
            SeqSpine(seq: event.seq, widestSeq: widestSeq)

            VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
                Button(action: toggle) {
                    VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
                        HStack(alignment: .firstTextBaseline, spacing: OpenPawTheme.Space.small) {
                            Text(event.body.typeName)
                                .font(OpenPawTheme.Machine.headline)
                                .foregroundStyle(tint)
                            if isUnsupported {
                                Text("unsupported").microLabel(OpenPawTheme.warn)
                            }
                            Spacer(minLength: OpenPawTheme.Space.small)
                            Text(ChatFormat.clock(event.timestamp))
                                .font(OpenPawTheme.Machine.codeSmall)
                                .foregroundStyle(OpenPawTheme.textTertiary)
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .imageScale(.small)
                                .foregroundStyle(OpenPawTheme.textTertiary)
                        }

                        Text(EventSummary.line(for: event))
                            .font(OpenPawTheme.Machine.body)
                            .foregroundStyle(OpenPawTheme.textSecondary)
                            .lineLimit(isExpanded ? nil : 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(event.body.typeName), sequence \(event.seq). \(EventSummary.line(for: event))")
                .accessibilityHint(isExpanded ? "Hides the payload" : "Shows the payload")

                if isExpanded {
                    VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
                        MonoField(label: "event id", value: event.eventID.rawValue, isCopyable: true)
                        MonoField(label: "session", value: event.sessionID.rawValue, isCopyable: true)
                        if let cwd = event.cwd {
                            MonoField(label: "cwd", value: cwd)
                        }
                        if let branch = event.gitBranch {
                            MonoField(label: "branch", value: branch)
                        }
                        if let target = event.multiplexerTarget {
                            MonoField(label: "target", value: target)
                        }
                        Text("payload").microLabel()
                        CodeBlock(
                            text: EventPayload.json(for: event),
                            language: .json,
                            showsLineNumbers: true,
                            firstLine: 1
                        )
                    }
                    .padding(.bottom, OpenPawTheme.Space.small)
                }
            }
        }
        .padding(.horizontal, OpenPawTheme.Space.large)
        .padding(.vertical, OpenPawTheme.Space.small)
    }
}

// MARK: - Previews

#Preview("Event log") {
    let model = PreviewBackend.model()
    return EventLogView(model: model, sessionID: PreviewBackend.claudeSessionID)
}

#Preview("Event log · empty") {
    let model = PreviewBackend.model(.empty)
    return EventLogView(model: model, sessionID: PreviewBackend.claudeSessionID)
}
