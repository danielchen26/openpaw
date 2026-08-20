import OpenPawProtocol
import SwiftUI

/// The consequential screen: the one place in OpenPaw where an agent can be allowed to do something.
///
/// It reads top to bottom the way the decision is actually made. The risk seal states the class in colour, glyph
/// and words. The summary is the sentence a person reads. Below it the machine register says exactly what would
/// run. Only then come the controls.
///
/// **The gate.** When the item's risk demands the full command and the reader has not opened it, this sheet has no
/// approve control at all — not a disabled one, none. The primary control slot holds `Show the full command`
/// instead, and taking it reveals the command and marks the detail acknowledged, after which the approve controls
/// appear and the seal consolidates. Deny and Stop are present throughout. The host enforces the same rule with a
/// 400 and `OpenPawModel.resolve` refuses locally, so this screen's job is to make the correct thing the only
/// visible thing.
public struct ApprovalSheet: View {
    private let model: OpenPawModel
    private let handed: InboxItem

    @State private var isDeciding = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: OpenPawModel, item: InboxItem) {
        self.model = model
        self.handed = item
    }

    /// The live copy, so an acknowledgement or a decision taken here is what the sheet re-renders from.
    private var item: InboxItem {
        model.inbox.first { $0.id == handed.id } ?? handed
    }

    private var facts: InboxItemFacts {
        InboxItemFacts(item: item, events: model.events(for: item.sessionID.rawValue))
    }

    /// An unclassified request is `unknown`, which the seal states in words rather than leaving blank.
    private var risk: Risk {
        item.risk ?? .unknown
    }

    /// True for every item that is not gated, and for a gated item once the command has been shown. One predicate
    /// decides both the reveal control and the approve controls, so they cannot disagree.
    private var isAcknowledged: Bool {
        model.isDetailAcknowledged(item)
    }

    public var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider().overlay(OpenPawTheme.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    RiskSeal(risk: risk, isAcknowledged: isAcknowledged)
                        .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: OpenPawTheme.Space.xl) {
                        summary
                        if risk.requiresDetailExpansion {
                            dangerRecap
                        }
                        machinePanel
                        if let command = InboxItemFacts.command(for: item) {
                            InboxCommandPanel(model: model, item: item, command: command)
                        }
                    }
                    .padding(OpenPawTheme.Space.large)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            controls
        }
        .background(OpenPawTheme.ink)
        #if os(iOS)
            .presentationDetents([.large])
        #endif
    }

    // MARK: - Chrome

    private var sheetHeader: some View {
        HStack(spacing: OpenPawTheme.Space.small) {
            Text("decision").microLabel(OpenPawTheme.textSecondary)
            Spacer(minLength: 0)
            Button {
                dismiss()
            } label: {
                Text("Close")
                    .font(OpenPawTheme.Human.proseTight)
                    .foregroundStyle(OpenPawTheme.textSecondary)
                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close without deciding")
        }
        .padding(.leading, OpenPawTheme.Space.large)
        .padding(.trailing, OpenPawTheme.Space.medium)
    }

    // MARK: - The sentence

    private var summary: some View {
        HumanPanel {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
                Text("\(item.agent.displayName) is asking").microLabel(OpenPawTheme.textSecondary)
                Text(item.title)
                    .font(OpenPawTheme.Human.title)
                    .foregroundStyle(OpenPawTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Names the specific triggers rather than warning in the abstract. "Danger" plus `rm removes files` tells the
    /// reader what to look for in the command; a generic caution tells them nothing and trains them to tap through.
    private var dangerRecap: some View {
        HStack(alignment: .firstTextBaseline, spacing: OpenPawTheme.Space.small) {
            Image(systemName: OpenPawTheme.glyph(for: risk.riskClass))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OpenPawTheme.bad)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
                Text("danger").microLabel(OpenPawTheme.bad)
                Text(recapLine)
                    .font(OpenPawTheme.Human.proseTight)
                    .foregroundStyle(OpenPawTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(OpenPawTheme.Space.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            OpenPawTheme.bad.opacity(0.10),
            in: RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card)
                .strokeBorder(OpenPawTheme.bad.opacity(0.45), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    /// One sentence, not a second copy of the seal's list.
    ///
    /// `RiskSeal` already enumerates `risk.reasons` as machine-register field lines directly above this, so
    /// repeating them as bullets here said everything twice. Joining them into prose is the point of the recap: the
    /// seal states the triggers as facts, this states them as the sentence a person reads before deciding.
    ///
    /// The class word is deliberately not interpolated. `OpenPawTheme.label(for:)` is a verb phrase — "touches
    /// credentials", "installs packages" — so "this request is touches credentials" is broken English for five of
    /// the eight classes, and the seal states the class anyway.
    private var recapLine: String {
        let reasons = risk.reasons.filter { !$0.isEmpty }
        guard !reasons.isEmpty else {
            return "The host flagged this as needing the full command before anyone approves it."
        }
        let joined: String
        if reasons.count == 1 {
            joined = reasons[0]
        } else {
            joined = reasons.dropLast().joined(separator: ", ") + ", and " + reasons[reasons.count - 1]
        }
        return "Read the command before you decide: \(joined)."
    }

    // MARK: - What would run

    private var machinePanel: some View {
        let session = model.session(item.sessionID.rawValue)
        return Panel(label: "what would run") {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                if let tool = facts.tool {
                    MonoField(label: "tool", value: tool)
                }
                if let cwd = facts.cwd ?? session?.cwd {
                    MonoField(label: "cwd", value: cwd, isCopyable: true)
                }
                if !facts.paths.isEmpty {
                    VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
                        Text(facts.paths.count == 1 ? "path" : "paths").microLabel()
                        ForEach(facts.paths, id: \.self) { path in
                            Text(path)
                                .font(OpenPawTheme.Machine.code)
                                .foregroundStyle(OpenPawTheme.textPrimary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                MonoField(label: "session", value: item.sessionID.rawValue)
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: OpenPawTheme.Space.small) {
            if let error = model.lastError {
                InlineErrorPanel(error: error) { model.lastError = nil }
            }
            decisionStack
        }
        .padding(OpenPawTheme.Space.large)
        .background(OpenPawTheme.ink)
        .overlay(alignment: .top) {
            Divider().overlay(OpenPawTheme.line)
        }
    }

    @ViewBuilder
    private var decisionStack: some View {
        if item.status != .pending {
            settledStrip
        } else if isDeciding {
            WorkingIndicator(label: "Sending your decision")
                .frame(maxWidth: .infinity)
                .frame(minHeight: 48)
        } else {
            if isAcknowledged {
                ForEach(approvals, id: \.self) { action in
                    DecisionButton(
                        title: InboxCopy.title(for: action),
                        glyph: InboxCopy.glyph(for: action),
                        caption: action == .approveAlways ? scopeCaption : nil,
                        emphasis: action == .approveOnce ? .primary : .secondary
                    ) {
                        decide(action)
                    }
                }
            } else {
                RevealCommandButton(action: reveal)
            }
            refusals
        }
    }

    /// Only what the host offered, and never a global always: `approve_always` is scoped to one tool at one risk
    /// class, which the caption states.
    private var approvals: [ActionID] {
        [.approveOnce, .approveAlways].filter { item.actions.contains($0) }
    }

    /// Deny and Stop are unconditional. Refusing is always the safe outcome, so a host that forgot to offer them
    /// must not be able to leave a reader with an approve control and no way out; a refusal the host rejects
    /// changes nothing, while a missing refusal changes everything.
    @ViewBuilder
    private var refusals: some View {
        DecisionButton(
            title: InboxCopy.title(for: .deny),
            glyph: InboxCopy.glyph(for: .deny),
            emphasis: .secondary
        ) {
            decide(.deny)
        }
        if item.actions.contains(.denyAlways) {
            DecisionButton(
                title: InboxCopy.title(for: .denyAlways),
                glyph: InboxCopy.glyph(for: .denyAlways),
                caption: scopeCaption,
                emphasis: .secondary
            ) {
                decide(.denyAlways)
            }
        }
        DecisionButton(
            title: InboxCopy.title(for: .stop),
            glyph: InboxCopy.glyph(for: .stop),
            emphasis: .secondary
        ) {
            decide(.stop)
        }
    }

    private var scopeCaption: String {
        "\(facts.tool ?? "this tool") · \(OpenPawTheme.label(for: risk.riskClass))"
    }

    private var settledStrip: some View {
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

    // MARK: - Actions

    /// One of the app's two permitted animations: the seal consolidating from hatched to solid once the command is
    /// on screen. Reduce Motion gets the same state change with no transition.
    private func reveal() {
        if reduceMotion {
            model.acknowledgeDetail(item)
        } else {
            withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.32)) {
                model.acknowledgeDetail(item)
            }
        }
    }

    /// A failure keeps the sheet open. Dismissing on error would throw away the one screen that holds the context
    /// needed to try again.
    private func decide(_ action: ActionID) {
        isDeciding = true
        Task {
            model.lastError = nil
            let sent = await model.resolve(item, action: action)
            isDeciding = false
            if sent { dismiss() }
        }
    }
}

// MARK: - Decision control

/// A decision control.
///
/// Hierarchy comes from fill versus outline, never from colour. The risk ramp is the only saturated thing on this
/// screen, and a green approve button competing with a red seal is precisely the confusion this app cannot afford.
struct DecisionButton: View {
    enum Emphasis {
        case primary
        case secondary
    }

    let title: String
    let glyph: String
    var caption: String? = nil
    var emphasis: Emphasis = .secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: OpenPawTheme.Space.small) {
                Image(systemName: glyph)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: OpenPawTheme.Space.hair) {
                    Text(title)
                        .font(OpenPawTheme.Human.proseTight)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let caption {
                        Text(caption).microLabel(captionColor)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, OpenPawTheme.Space.large)
            .padding(.vertical, OpenPawTheme.Space.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 48)
            .background(background, in: RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card))
            .overlay(
                RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card)
                    .strokeBorder(border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(caption.map { "\(title). Scoped to \($0)." } ?? title)
    }

    private var foreground: Color {
        switch emphasis {
        case .primary: OpenPawTheme.ink
        case .secondary: OpenPawTheme.textPrimary
        }
    }

    private var background: Color {
        switch emphasis {
        case .primary: OpenPawTheme.textPrimary
        case .secondary: OpenPawTheme.panel
        }
    }

    private var border: Color {
        switch emphasis {
        case .primary: OpenPawTheme.textPrimary
        case .secondary: OpenPawTheme.lineStrong
        }
    }

    private var captionColor: Color {
        switch emphasis {
        case .primary: OpenPawTheme.well
        case .secondary: OpenPawTheme.textTertiary
        }
    }
}

// MARK: - Inline error

/// An error stays where the decision is, states what happened and says what to do next. It never apologises and it
/// never replaces the controls — the reader can read it and try again without losing the screen.
struct InlineErrorPanel: View {
    let error: PresentedError
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: OpenPawTheme.Space.small) {
            Image(systemName: error.isRecoverable ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.hair) {
                Text(error.title)
                    .font(OpenPawTheme.Human.proseTight)
                    .foregroundStyle(OpenPawTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(error.detail)
                    .font(OpenPawTheme.Human.caption)
                    .foregroundStyle(OpenPawTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(OpenPawTheme.textTertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss this message")
        }
        .padding(.leading, OpenPawTheme.Space.medium)
        .padding(.vertical, OpenPawTheme.Space.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OpenPawTheme.panelWarm, in: RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card)
                .strokeBorder(tint.opacity(0.45), lineWidth: 1)
        )
    }

    private var tint: Color {
        error.isRecoverable ? OpenPawTheme.warn : OpenPawTheme.bad
    }
}

// MARK: - Previews

#Preview("Approval · gated, command not yet shown") {
    let model = PreviewBackend.model(.reviewingDestructiveCommand)
    InboxApprovalPreview(model: model, pick: { $0.risk?.requiresDetailExpansion == true })
}

#Preview("Approval · command shown, approvals present") {
    let model = PreviewBackend.model(.reviewingDestructiveCommand)
    let gated = model.pendingInbox.first { $0.risk?.requiresDetailExpansion == true }
    let _ = gated.map { model.acknowledgeDetail($0) }
    InboxApprovalPreview(model: model, pick: { $0.risk?.requiresDetailExpansion == true })
}

#Preview("Approval · ungated request") {
    let model = PreviewBackend.model(.populated)
    InboxApprovalPreview(
        model: model,
        pick: { $0.category == .permission && $0.risk?.requiresDetailExpansion != true }
    )
}

/// Picks a fixture item out of a scenario for a preview, and says so plainly when the scenario carries none.
struct InboxApprovalPreview: View {
    let model: OpenPawModel
    let pick: (InboxItem) -> Bool

    var body: some View {
        if let item = model.inbox.first(where: pick) ?? model.pendingInbox.first {
            ApprovalSheet(model: model, item: item)
        } else {
            EmptyStateView(
                glyph: "hand.raised",
                title: "This scenario has no permission request",
                message: "Use PreviewBackend.reviewingDestructiveCommand, which supplies the gated request this "
                    + "sheet exists for."
            )
        }
    }
}
