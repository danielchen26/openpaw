import Foundation
import OpenPawProtocol
import SwiftUI

/// One inbox item in full: what was asked, by which agent, out of which session, and on what evidence.
///
/// This screen never grants anything. Every approval in the product goes through `ApprovalSheet`, so the gate is
/// implemented exactly once — two screens that both know how to approve are two chances to get the most important
/// interaction in the app wrong.
public struct InboxItemDetailView: View {
    private let model: OpenPawModel
    private let handed: InboxItem

    @State private var answer = ""
    @State private var isDeciding = false
    @State private var isApproving = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: OpenPawModel, item: InboxItem) {
        self.model = model
        self.handed = item
    }

    /// Reads the live copy so a decision taken in the approval sheet lands on this screen instead of leaving a
    /// stale status on it. Falls back to the item we were handed, which keeps the screen renderable when the host
    /// has already dropped the item and in previews built from a synthesized item.
    private var item: InboxItem {
        model.inbox.first { $0.id == handed.id } ?? handed
    }

    private var facts: InboxItemFacts {
        InboxItemFacts(item: item, events: model.events(for: item.sessionID.rawValue))
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.xl) {
                header
                requestPanel
                if let risk = item.risk, !risk.reasons.isEmpty {
                    reasonsPanel(risk)
                }
                if let command = InboxItemFacts.command(for: item) {
                    InboxCommandPanel(model: model, item: item, command: command)
                }
                if !facts.choices.isEmpty {
                    choicesPanel
                }
                if !facts.planSteps.isEmpty {
                    planPanel
                }
                if let report = reportText {
                    reportPanel(report)
                }
            }
            .padding(OpenPawTheme.Space.large)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(OpenPawTheme.ink)
        .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
        .navigationTitle(InboxCopy.title(for: item.category))
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $isApproving) {
            ApprovalSheet(model: model, item: item)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
            HStack(spacing: OpenPawTheme.Space.small) {
                Image(systemName: OpenPawTheme.glyph(for: item.category))
                    .font(.system(size: 13))
                    .foregroundStyle(OpenPawTheme.color(for: item.category))
                    .accessibilityHidden(true)
                Text(InboxCopy.title(for: item.category)).microLabel(OpenPawTheme.textSecondary)
                if let risk = item.risk {
                    RiskChip(risk: risk, style: .inline)
                }
                Spacer(minLength: 0)
            }
            Text(item.title)
                .font(titleFont)
                .foregroundStyle(OpenPawTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A permission and a question are sentences the agent addressed to a person, so they read in the human
    /// register. Everything else on this screen is the machine reporting a fact about itself.
    private var titleFont: Font {
        switch item.category {
        case .permission, .question: OpenPawTheme.Human.title
        default: OpenPawTheme.Machine.title
        }
    }

    // MARK: - Panels

    private var requestPanel: some View {
        let summary = model.session(item.sessionID.rawValue)
        return Panel(label: "request") {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                MonoField(label: "session", value: item.sessionID.rawValue, isCopyable: true)
                MonoField(label: "agent", value: item.agent.displayName)
                if let branch = summary?.gitBranch {
                    MonoField(label: "branch", value: branch)
                }
                MonoField(label: "created", value: MachineTime.stamp(item.createdAt))
                if let expiresAt = item.expiresAt {
                    MonoField(label: "expires", value: MachineTime.stamp(expiresAt))
                }
                if let tool = facts.tool {
                    MonoField(label: "tool", value: tool)
                }
                if let cwd = facts.cwd ?? summary?.cwd {
                    MonoField(label: "cwd", value: cwd, isCopyable: true)
                }
                if !facts.paths.isEmpty {
                    pathList(facts.paths)
                }
            }
        }
    }

    private func pathList(_ paths: [String]) -> some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
            Text(paths.count == 1 ? "path" : "paths").microLabel()
            ForEach(paths, id: \.self) { path in
                Text(path)
                    .font(OpenPawTheme.Machine.code)
                    .foregroundStyle(OpenPawTheme.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Labelled just `why`: interpolating the class word produced "why it is reads only" and "why it is installs
    /// packages" for five of the eight classes. The class is already stated in words, glyph and colour by the chip
    /// in the header, so this panel only has to answer the question.
    private func reasonsPanel(_ risk: Risk) -> some View {
        Panel(label: "why") {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
                ForEach(risk.reasons, id: \.self) { reason in
                    HStack(alignment: .firstTextBaseline, spacing: OpenPawTheme.Space.small) {
                        Text("—")
                            .font(OpenPawTheme.Machine.code)
                            .foregroundStyle(OpenPawTheme.color(for: risk.riskClass))
                            .accessibilityHidden(true)
                        Text(reason)
                            .font(OpenPawTheme.Human.proseTight)
                            .foregroundStyle(OpenPawTheme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private var choicesPanel: some View {
        HumanPanel {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
                Text("choices").microLabel(OpenPawTheme.textSecondary)
                ForEach(facts.choices, id: \.self) { choice in
                    Button {
                        decide(.answer, answer: choice)
                    } label: {
                        HStack(spacing: OpenPawTheme.Space.small) {
                            Text(choice)
                                .font(OpenPawTheme.Human.prose)
                                .foregroundStyle(OpenPawTheme.textPrimary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(OpenPawTheme.textTertiary)
                        }
                        .padding(OpenPawTheme.Space.medium)
                        .frame(minHeight: 44)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            OpenPawTheme.panel,
                            in: RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card)
                                .strokeBorder(OpenPawTheme.line, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Answer: \(choice)")
                }
            }
        }
        .disabled(item.status != .pending || isDeciding)
    }

    private var planPanel: some View {
        Panel(label: "plan") {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
                ForEach(facts.planSteps) { step in
                    HStack(alignment: .firstTextBaseline, spacing: OpenPawTheme.Space.small) {
                        Text(step.status.marker)
                            .font(OpenPawTheme.Machine.code)
                            .foregroundStyle(color(for: step.status))
                        Text(step.title)
                            .font(OpenPawTheme.Human.proseTight)
                            .foregroundStyle(
                                step.status == .cancelled ? OpenPawTheme.textTertiary : OpenPawTheme.textPrimary
                            )
                            .strikethrough(step.status == .cancelled, color: OpenPawTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: OpenPawTheme.Space.small)
                        Text(word(for: step.status)).microLabel()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(word(for: step.status)). \(step.title)")
                }
            }
        }
    }

    /// The machine's own report about itself. A permission's detail is the command, a question's is the choice
    /// list and a plan's is the step list — all three are rendered by their own panel, so only the notifications
    /// land here.
    private var reportText: String? {
        switch item.category {
        case .permission, .question, .plan: nil
        case .toolFailure, .completion, .contextWarning, .rateLimit, .backgroundJob: item.detail
        }
    }

    @ViewBuilder
    private func reportPanel(_ text: String) -> some View {
        switch item.category {
        case .completion:
            HumanPanel {
                VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
                    Text("what it says").microLabel(OpenPawTheme.textSecondary)
                    Text(text)
                        .font(OpenPawTheme.Human.prose)
                        .foregroundStyle(OpenPawTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .toolFailure:
            Panel(label: "error") {
                CodeBlock(text: text, language: .plain)
            }
        default:
            Panel(label: "detail") {
                Text(text)
                    .font(OpenPawTheme.Machine.body)
                    .foregroundStyle(OpenPawTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        VStack(spacing: OpenPawTheme.Space.small) {
            if let error = model.lastError {
                InlineErrorPanel(error: error) { model.lastError = nil }
            }
            controls
        }
        .padding(OpenPawTheme.Space.large)
        .background(OpenPawTheme.ink)
        .overlay(alignment: .top) {
            Divider().overlay(OpenPawTheme.line)
        }
    }

    @ViewBuilder
    private var controls: some View {
        if item.status != .pending {
            decidedStrip
        } else if isDeciding {
            WorkingIndicator(label: "Sending your decision")
                .frame(maxWidth: .infinity)
                .frame(minHeight: 48)
        } else if !model.isDetailAcknowledged(item) {
            RevealCommandButton(action: reveal)
        } else if hasApproval {
            DecisionButton(title: "Review and decide", glyph: "checkmark.shield", emphasis: .primary) {
                isApproving = true
            }
        } else {
            if showsAnswerField {
                answerField
            }
            ForEach(closingActions, id: \.self) { action in
                DecisionButton(
                    title: InboxCopy.title(for: action),
                    glyph: InboxCopy.glyph(for: action),
                    emphasis: action == .acknowledge ? .primary : .secondary
                ) {
                    decide(action)
                }
            }
        }
    }

    private var answerField: some View {
        HStack(alignment: .bottom, spacing: OpenPawTheme.Space.small) {
            TextField("Type your answer", text: $answer, axis: .vertical)
                .textFieldStyle(.plain)
                .font(OpenPawTheme.Human.prose)
                .foregroundStyle(OpenPawTheme.textPrimary)
                .lineLimit(1...4)
                .padding(.horizontal, OpenPawTheme.Space.medium)
                .padding(.vertical, OpenPawTheme.Space.small)
                .frame(minHeight: 44)
                .background(
                    OpenPawTheme.panelWarm,
                    in: RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card)
                        .strokeBorder(OpenPawTheme.line, lineWidth: 1)
                )

            Button {
                decide(.answer, answer: trimmedAnswer)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(trimmedAnswer.isEmpty ? OpenPawTheme.textTertiary : OpenPawTheme.ink)
                    .frame(width: 44, height: 44)
                    .background(
                        trimmedAnswer.isEmpty ? OpenPawTheme.panel : OpenPawTheme.textPrimary,
                        in: RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(trimmedAnswer.isEmpty)
            .accessibilityLabel("Send your answer")
        }
    }

    private var decidedStrip: some View {
        HStack(alignment: .firstTextBaseline, spacing: OpenPawTheme.Space.small) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 12))
                .foregroundStyle(OpenPawTheme.textTertiary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.hair) {
                Text("already decided").microLabel()
                Text(InboxCopy.decision(for: item))
                    .font(OpenPawTheme.Human.proseTight)
                    .foregroundStyle(OpenPawTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
    }

    // MARK: - Derived state

    private var hasApproval: Bool {
        item.actions.contains { $0.isApproval }
    }

    /// A question with no choices can only be answered in prose, so the field appears whether or not the host
    /// bothered to set `allows_free_text`.
    private var showsAnswerField: Bool {
        item.actions.contains(.answer) && (facts.allowsFreeText || facts.choices.isEmpty)
    }

    /// Everything this screen may settle on its own, in a fixed order so the bar does not reshuffle between items.
    private var closingActions: [ActionID] {
        [.acknowledge, .deny, .denyAlways, .stop].filter { item.actions.contains($0) }
    }

    private var trimmedAnswer: String {
        answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func color(for status: PlanStepStatus) -> Color {
        switch status {
        case .pending: OpenPawTheme.textTertiary
        case .inProgress: OpenPawTheme.warn
        case .completed: OpenPawTheme.ok
        case .cancelled: OpenPawTheme.textTertiary
        }
    }

    private func word(for status: PlanStepStatus) -> String {
        switch status {
        case .pending: "waiting"
        case .inProgress: "running"
        case .completed: "done"
        case .cancelled: "dropped"
        }
    }

    // MARK: - Actions

    /// One of the app's two permitted animations: the risk seal consolidating once the command is on screen.
    private func reveal() {
        if reduceMotion {
            model.acknowledgeDetail(item)
        } else {
            withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.32)) {
                model.acknowledgeDetail(item)
            }
        }
    }

    private func decide(_ action: ActionID, answer text: String? = nil) {
        isDeciding = true
        Task {
            model.lastError = nil
            let sent = await model.resolve(item, action: action, answer: text)
            isDeciding = false
            if sent { answer = "" }
        }
    }
}

// MARK: - Command panel and the gate in front of it

/// The command, and nothing where the command would be until the reader asks for it.
///
/// The reveal control deliberately lives elsewhere — in the primary control slot at the bottom of the screen, the
/// same slot the approve control would occupy. That way the next correct action is always the one under the thumb,
/// and an approve control never has to be drawn and then disabled.
struct InboxCommandPanel: View {
    let model: OpenPawModel
    let item: InboxItem
    let command: String

    var body: some View {
        Panel(label: "command") {
            if model.isDetailAcknowledged(item) {
                CodeBlock(text: command, language: .shell)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: OpenPawTheme.Space.small) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 11))
                        .foregroundStyle(OpenPawTheme.textTertiary)
                        .accessibilityHidden(true)
                    Text("Open it with the control below. This one is never approved unseen.")
                        .font(OpenPawTheme.Human.proseTight)
                        .foregroundStyle(OpenPawTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
            }
        }
    }
}

/// The gate control. Defined once so the approval sheet and the detail screen cannot drift on the most important
/// label in the product.
struct RevealCommandButton: View {
    let action: () -> Void

    var body: some View {
        DecisionButton(title: "Show the full command", glyph: "eye", emphasis: .primary, action: action)
            .accessibilityHint("Approving is not possible until the command is on screen.")
    }
}

// MARK: - Facts

/// What a decision screen needs to know about an item beyond the item itself.
///
/// `InboxItem` carries only what a push payload can. The tool, the working directory, the paths, a question's
/// choices and a plan's steps live in the event the item was projected from, so we read that event when the
/// transcript holds it. When it does not — the normal case for an inbox fetched over REST after a cold start —
/// `detail` is `InboxProjection`'s own rendering of the same payload, and reading it back is exact because both
/// sides of the wire use that one projection.
struct InboxItemFacts {
    let tool: String?
    let cwd: String?
    let paths: [String]
    let choices: [String]
    let allowsFreeText: Bool
    let planSteps: [PlanStep]

    init(item: InboxItem, events: [Event]) {
        let source = events.first { $0.eventID == item.sourceEventID }
        var tool: String?
        var paths: [String] = []
        var choices: [String] = []
        var allowsFreeText = false
        var steps: [PlanStep] = []

        switch source?.body {
        case .some(.permissionRequested(let payload)):
            tool = payload.tool
            paths = payload.paths
        case .some(.questionRequested(let payload)):
            choices = payload.choices
            allowsFreeText = payload.allowsFreeText
        case .some(.planCreated(let payload)), .some(.planUpdated(let payload)):
            steps = payload.steps
        default:
            switch item.category {
            case .question:
                choices = Self.choices(from: item.detail)
                allowsFreeText = choices.isEmpty
            case .plan:
                steps = Self.steps(from: item.detail)
            default:
                break
            }
        }

        self.tool = tool
        self.cwd = source?.cwd
        self.paths = paths
        self.choices = choices
        self.allowsFreeText = allowsFreeText
        self.planSteps = steps
    }

    /// The text the gate is about. The projection copies a permission's command into `detail` as well, so a
    /// permission always has something to reveal even when the host sent no separate `command`.
    static func command(for item: InboxItem) -> String? {
        if let command = item.command, !command.isEmpty { return command }
        guard item.category == .permission, let detail = item.detail, !detail.isEmpty else { return nil }
        return detail
    }

    /// `InboxProjection` joins a question's choices with `", "`.
    private static func choices(from detail: String?) -> [String] {
        guard let detail, !detail.contains("\n") else { return [] }
        return detail
            .components(separatedBy: ", ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// `InboxProjection` renders a plan as one `PlanStepStatus.marker` prefixed line per step.
    private static func steps(from detail: String?) -> [PlanStep] {
        guard let detail else { return [] }
        var steps: [PlanStep] = []
        for (index, line) in detail.split(separator: "\n").enumerated() {
            let text = String(line)
            guard let status = PlanStepStatus.allCases.first(where: { text.hasPrefix($0.marker) }) else { continue }
            let title = text.dropFirst(status.marker.count).trimmingCharacters(in: .whitespaces)
            steps.append(PlanStep(id: "step-\(index)", title: title, status: status))
        }
        return steps
    }
}

// MARK: - Machine-register time

/// Fixed-width, locale-independent timestamps for the machine register.
///
/// `DateFormatter` is not `Sendable`, so it cannot be a shared constant under Swift 6, and a localized stamp
/// changes width between rows — which is the one thing a monospaced column must not do.
enum MachineTime {
    static func stamp(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date
        )
        return String(
            format: "%04d-%02d-%02d %02d:%02d:%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0,
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0
        )
    }

    static func clock(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }
}

// MARK: - Previews

#Preview("Detail · destructive permission") {
    let model = PreviewBackend.model(.reviewingDestructiveCommand)
    return NavigationStack {
        InboxDetailPreview(model: model, pick: { $0.risk?.requiresDetailExpansion == true })
    }
}

#Preview("Detail · question") {
    let model = PreviewBackend.model(.populated)
    return NavigationStack {
        InboxDetailPreview(model: model, pick: { $0.category == .question })
    }
}

#Preview("Detail · plan") {
    let model = PreviewBackend.model(.populated)
    return NavigationStack {
        InboxDetailPreview(model: model, pick: { $0.category == .plan })
    }
}

#Preview("Detail · already decided") {
    let model = PreviewBackend.model(.populated)
    return NavigationStack {
        InboxDetailPreview(model: model, pick: { $0.status != .pending })
    }
}

/// Picks a fixture item out of a scenario for a preview, and says so plainly when the scenario carries none.
struct InboxDetailPreview: View {
    let model: OpenPawModel
    let pick: (InboxItem) -> Bool

    var body: some View {
        if let item = model.inbox.first(where: pick) ?? model.pendingInbox.first {
            InboxItemDetailView(model: model, item: item)
        } else {
            EmptyStateView(
                glyph: "tray",
                title: "This scenario has no matching item",
                message: "PreviewBackend supplies inbox fixtures per scenario. Pick a scenario that contains the "
                    + "category this preview renders."
            )
        }
    }
}
