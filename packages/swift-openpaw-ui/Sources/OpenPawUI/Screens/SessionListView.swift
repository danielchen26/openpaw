import Foundation
import OpenPawProtocol
import OpenPawTerminalCore
import SwiftUI

// MARK: - State presentation

/// A session's state as a glyph, a word and a tone. The word is never dropped: a coloured dot on its own asks the
/// reader to remember a legend, and the one state that matters — an agent waiting for you — must be unmissable.
public struct SessionStatePresentation: Sendable, Hashable {
    public let label: String
    public let glyph: String
    public let tone: Color

    public static func make(_ state: SessionState) -> SessionStatePresentation {
        switch state {
        case .idle:
            SessionStatePresentation(
                label: "idle", glyph: "pause.circle.fill", tone: OpenPawTheme.textTertiary)
        case .working:
            SessionStatePresentation(
                label: "working", glyph: "arrow.triangle.2.circlepath", tone: OpenPawTheme.textPrimary)
        case .waiting:
            SessionStatePresentation(
                label: "waiting for you", glyph: "hand.raised.fill", tone: OpenPawTheme.warn)
        case .failed:
            SessionStatePresentation(label: "failed", glyph: "xmark.octagon.fill", tone: OpenPawTheme.bad)
        case .exited:
            SessionStatePresentation(label: "exited", glyph: "power", tone: OpenPawTheme.textTertiary)
        }
    }
}

// MARK: - Session list

/// Agent sessions grouped by the agent that owns them, plus the multiplexer sessions the host is holding open.
///
/// The two halves are deliberately different things and are labelled as such: the top half is agents OpenPaw
/// understands and can show a transcript for, the bottom half is raw tmux-style sessions that exist whether or not
/// an agent is inside them. Merging them would suggest the app knows more about the second kind than it does.
@MainActor
public struct SessionListView: View {
    private let model: OpenPawModel
    private let remoteSessions: [RemoteSession]
    private let restoration: SessionRestorationPlan?
    private let transport: SessionTransportPresentation
    private let onSelect: ((SessionSummary) -> Void)?
    private let onAttach: (RemoteSession) -> Void
    private let onCreate: (String) -> Void
    private let onRename: (RemoteSession, String) -> Void
    private let onKill: (RemoteSession) -> Void
    private let onRestore: (SessionRestorationPlan) -> Void
    private let onRefresh: () async -> Void

    @State private var newSessionName = ""
    @State private var renamingID: String?
    @State private var renameText = ""
    @State private var pendingKill: RemoteSession?

    public init(
        model: OpenPawModel,
        remoteSessions: [RemoteSession] = [],
        restoration: SessionRestorationPlan? = nil,
        transport: SessionTransportPresentation = .init(),
        onSelect: ((SessionSummary) -> Void)? = nil,
        onAttach: @escaping (RemoteSession) -> Void = { _ in },
        onCreate: @escaping (String) -> Void = { _ in },
        onRename: @escaping (RemoteSession, String) -> Void = { _, _ in },
        onKill: @escaping (RemoteSession) -> Void = { _ in },
        onRestore: @escaping (SessionRestorationPlan) -> Void = { _ in },
        onRefresh: @escaping () async -> Void = { }
    ) {
        self.model = model
        self.remoteSessions = remoteSessions
        self.restoration = restoration
        self.transport = transport
        self.onSelect = onSelect
        self.onAttach = onAttach
        self.onCreate = onCreate
        self.onRename = onRename
        self.onKill = onKill
        self.onRestore = onRestore
        self.onRefresh = onRefresh
    }

    /// Sessions grouped by owning agent. A named struct rather than a tuple because `ForEach` needs a key path
    /// for identity, and Swift has no key paths into tuples.
    struct AgentGroup: Identifiable {
        let agent: AgentKind
        let sessions: [SessionSummary]
        var id: AgentKind { agent }
    }

    private var groups: [AgentGroup] {
        Dictionary(grouping: model.sessions, by: \.agent)
            .map { AgentGroup(agent: $0.key, sessions: $0.value.sorted(by: Self.recencyOrder)) }
            .sorted { $0.agent.displayName < $1.agent.displayName }
    }

    /// Selecting a session follows it. Callers can override to also push a detail view; the default keeps the
    /// list useful on its own.
    private func select(_ session: SessionSummary) {
        if let onSelect {
            onSelect(session)
            return
        }
        model.selectedSessionID = session.sessionID
        model.startFollowing(session: session.sessionID)
    }

    /// Sessions that want attention float up, then the most recently active. A list of agents is a queue.
    private static func recencyOrder(_ lhs: SessionSummary, _ rhs: SessionSummary) -> Bool {
        if lhs.pendingInbox != rhs.pendingInbox { return lhs.pendingInbox > rhs.pendingInbox }
        let left = lhs.lastEventAt ?? .distantPast
        let right = rhs.lastEventAt ?? .distantPast
        return left > right
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.large) {
                if let restoration {
                    restorationBanner(restoration)
                }

                if model.sessions.isEmpty {
                    EmptyStateView(
                        glyph: "terminal",
                        title: "No agent sessions",
                        message:
                            "Start an agent on the host and it appears here. OpenPaw reads the transcripts the "
                            + "agents already write, so there is nothing extra to configure.",
                        actionTitle: "Refresh",
                        action: { Task { await onRefresh() } }
                    )
                } else {
                    ForEach(groups) { group in
                        Panel(label: group.agent.displayName) {
                            VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
                                ForEach(group.sessions) { session in
                                    sessionRow(session)
                                }
                            }
                        }
                    }
                }

                multiplexer
            }
            .padding(OpenPawTheme.Space.large)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .background(OpenPawTheme.ink)
        .navigationTitle("Sessions")
        .refreshable { await onRefresh() }
        .confirmationDialog(
            pendingKill.map { "Kill \($0.name)?" } ?? "Kill session?",
            isPresented: killBinding,
            titleVisibility: .visible,
            presenting: pendingKill
        ) { session in
            Button("Kill \(session.name)", role: .destructive) {
                onKill(session)
                pendingKill = nil
            }
            Button("Keep", role: .cancel) {}
        } message: { _ in
            Text(
                "Ends the session and every process inside it. Anything an agent has not written to disk is lost."
            )
        }
    }

    // MARK: Agent session row

    private func sessionRow(_ session: SessionSummary) -> some View {
        let status = SessionStatePresentation.make(session.state)
        let isSelected = session.sessionID == model.selectedSessionID
        return Button {
            select(session)
        } label: {
            HStack(alignment: .top, spacing: OpenPawTheme.Space.medium) {
                Rectangle()
                    .fill(isSelected ? OpenPawTheme.lineStrong : Color.clear)
                    .frame(width: 2)
                    .accessibilityHidden(true)

                Image(systemName: status.glyph)
                    .font(OpenPawTheme.Machine.body)
                    .foregroundStyle(status.tone)
                    .frame(width: 20)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
                    HStack(alignment: .firstTextBaseline, spacing: OpenPawTheme.Space.small) {
                        // The title is the one human sentence in the row, so it gets the serif face.
                        Text(session.title ?? session.sessionID)
                            .font(OpenPawTheme.Human.proseTight)
                            .foregroundStyle(OpenPawTheme.textPrimary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: OpenPawTheme.Space.small)
                        if session.pendingInbox > 0 {
                            pendingBadge(session.pendingInbox)
                        }
                    }

                    Text(status.label).microLabel(status.tone)

                    if let cwd = session.cwd {
                        Text(cwd)
                            .font(OpenPawTheme.Machine.codeSmall)
                            .foregroundStyle(OpenPawTheme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }

                    ShellWrap(spacing: OpenPawTheme.Space.large) {
                        if let branch = session.gitBranch {
                            factChip("branch", branch)
                        }
                        if let target = session.multiplexerTarget {
                            factChip("mux", target)
                        }
                        factChip("seq", String(session.lastSeq))
                        VStack(alignment: .leading, spacing: OpenPawTheme.Space.hair) {
                            Text("last event").microLabel()
                            if let last = session.lastEventAt {
                                RelativeTime(date: last)
                                    .font(OpenPawTheme.Machine.codeSmall)
                                    .foregroundStyle(OpenPawTheme.textSecondary)
                            } else {
                                Text("none")
                                    .font(OpenPawTheme.Machine.codeSmall)
                                    .foregroundStyle(OpenPawTheme.textTertiary)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, OpenPawTheme.Space.small)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // VoiceOver hears the state first: it decides whether the rest of the row matters.
        .accessibilityLabel(rowVoiceLabel(session, status: status))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// VoiceOver hears the state first: it decides whether the rest of the row matters at all.
    private func rowVoiceLabel(_ session: SessionSummary, status: SessionStatePresentation) -> String {
        let title = session.title ?? session.sessionID
        guard session.pendingInbox > 0 else { return "\(status.label). \(title)" }
        return "\(status.label). \(title). \(session.pendingInbox) waiting for a decision"
    }

    private func windowSummary(_ session: RemoteSession) -> String {
        session.windowCount == 1 ? "1 window" : "\(session.windowCount) windows"
    }

    private func pendingBadge(_ count: Int) -> some View {
        HStack(spacing: OpenPawTheme.Space.tight) {
            Image(systemName: "hand.raised.fill").font(OpenPawTheme.Machine.codeSmall)
            Text("\(count)").font(OpenPawTheme.Machine.label)
        }
        .padding(.horizontal, OpenPawTheme.Space.small)
        .padding(.vertical, OpenPawTheme.Space.hair)
        .foregroundStyle(OpenPawTheme.ink)
        .background(OpenPawTheme.warn)
        .clipShape(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.chip))
        .accessibilityHidden(true)
    }

    private func factChip(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.hair) {
            Text(label).microLabel()
            Text(value)
                .font(OpenPawTheme.Machine.codeSmall)
                .foregroundStyle(OpenPawTheme.textSecondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Restoration

    private func restorationBanner(_ plan: SessionRestorationPlan) -> some View {
        let item = SessionSpacePresentation(agentSessions: model.sessions, remoteSessions: remoteSessions, restoration: plan, transport: transport).restorationItem
        return HumanPanel {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
                Text("Left running").microLabel()
                Text(item?.stateLabel == "stale target" ? "Previous session is gone." : "Your session kept working without you.")
                    .font(OpenPawTheme.Human.title)
                    .foregroundStyle(OpenPawTheme.textPrimary)
                Text(restorationProse(plan, item: item))
                    .font(OpenPawTheme.Human.prose)
                    .foregroundStyle(OpenPawTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    onRestore(plan)
                } label: {
                    Text(item?.primaryAction ?? "Start where you left off")
                        .font(OpenPawTheme.Machine.headline)
                        .padding(.horizontal, OpenPawTheme.Space.medium)
                        .frame(minHeight: 44)
                        .foregroundStyle(OpenPawTheme.ink)
                        .background(OpenPawTheme.textPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(restorationActionLabel(plan, item: item))
            }
        }
    }

    /// Says how long it has been and what reattaching will land on. `capturedAt` is when the app last knew the
    /// session's shape, so the elapsed time is measured from there rather than from a guess.
    private func restorationProse(_ plan: SessionRestorationPlan, item: SessionSpaceItem?) -> String {
        let elapsed = formatApproximateDuration(Date().timeIntervalSince(plan.capturedAt))
        if item?.stateLabel == "stale target", let target = plan.multiplexerTarget, let kind = plan.multiplexer {
            let directory = plan.workingDirectory ?? "the last directory"
            return "You were away \(elapsed). \(kind.displayName) no longer has \(target) alive, so OpenPaw can start a replacement session in \(directory)."
        }
        guard plan.isReattachable, let target = plan.multiplexerTarget else {
            let directory = plan.workingDirectory ?? "the last directory"
            return """
                You were away \(elapsed). There was no multiplexer session to hold your work, so OpenPaw can only \
                reopen a shell in \(directory).
                """
        }
        let name = plan.multiplexer?.displayName ?? "the multiplexer"
        return """
            You were away \(elapsed). \(name) held \(target) open the whole time, so reattaching picks it up \
            exactly where it is.
            """
    }

    private func restorationActionLabel(_ plan: SessionRestorationPlan, item: SessionSpaceItem?) -> String {
        if item?.stateLabel == "stale target" { return "Create a replacement session in the last working directory" }
        guard let target = plan.multiplexerTarget, plan.isReattachable else {
            return "Open a shell in the last working directory"
        }
        return "Reattach to \(target)"
    }

    // MARK: Multiplexer

    private var multiplexer: some View {
        Panel(label: "On the host") {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                if remoteSessions.isEmpty {
                    Text(SessionSpacePresentation(agentSessions: model.sessions, remoteSessions: remoteSessions, restoration: restoration, transport: transport).emptyRemoteMessage)
                    .font(OpenPawTheme.Human.caption)
                    .foregroundStyle(OpenPawTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(remoteSessions) { session in
                        remoteRow(session)
                    }
                }

                if let preferenceLabel = transport.preferenceLabel {
                    Text(preferenceLabel).microLabel(OpenPawTheme.textTertiary)
                }
                if let discoveryLabel = transport.discoveryLabel {
                    Text(discoveryLabel).microLabel(OpenPawTheme.textTertiary)
                }

                HStack(spacing: OpenPawTheme.Space.small) {
                    ShellField(label: "New session", placeholder: "openpaw", text: $newSessionName)
                    Button("Create") {
                        let name = newSessionName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        onCreate(name)
                        newSessionName = ""
                    }
                    .buttonStyle(.plain)
                    .font(OpenPawTheme.Machine.label)
                    .frame(minHeight: 44)
                    .foregroundStyle(OpenPawTheme.textPrimary)
                    .disabled(newSessionName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func remoteRow(_ session: RemoteSession) -> some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
            HStack(alignment: .firstTextBaseline, spacing: OpenPawTheme.Space.small) {
                Image(systemName: session.isAttached ? "rectangle.connected.to.line.below" : "rectangle")
                    .font(OpenPawTheme.Machine.codeSmall)
                    .foregroundStyle(session.isAttached ? OpenPawTheme.ok : OpenPawTheme.textTertiary)
                    .accessibilityHidden(true)
                Text(session.name)
                    .font(OpenPawTheme.Machine.body)
                    .foregroundStyle(OpenPawTheme.textPrimary)
                Text(session.kind.displayName)
                    .microLabel(OpenPawTheme.textTertiary)
                Text(session.isAttached ? "attached" : "detached")
                    .microLabel(session.isAttached ? OpenPawTheme.ok : OpenPawTheme.textTertiary)
                if !session.isAlive {
                    Text("dead").microLabel(OpenPawTheme.bad)
                }
                Spacer(minLength: 0)
                Text(windowSummary(session))
                    .font(OpenPawTheme.Machine.codeSmall)
                    .foregroundStyle(OpenPawTheme.textTertiary)
            }

            if renamingID == session.id {
                HStack(spacing: OpenPawTheme.Space.small) {
                    ShellField(label: "Rename to", placeholder: session.name, text: $renameText)
                    Button("Save") {
                        let name = renameText.trimmingCharacters(in: .whitespaces)
                        if !name.isEmpty { onRename(session, name) }
                        renamingID = nil
                    }
                    .buttonStyle(.plain)
                    .font(OpenPawTheme.Machine.label)
                    .frame(minHeight: 44)
                    .foregroundStyle(OpenPawTheme.textPrimary)
                    Button("Cancel") { renamingID = nil }
                        .buttonStyle(.plain)
                        .font(OpenPawTheme.Machine.label)
                        .frame(minHeight: 44)
                        .foregroundStyle(OpenPawTheme.textSecondary)
                }
            } else {
                HStack(spacing: OpenPawTheme.Space.large) {
                    // A dead session cannot be attached to. Offering it anyway just spends a round trip to learn
                    // what the row already says; killing it is the only useful thing left.
                    Button("Attach") { onAttach(session) }
                        .buttonStyle(.plain)
                        .font(OpenPawTheme.Machine.label)
                        .frame(minHeight: 44)
                        .foregroundStyle(session.isAlive ? OpenPawTheme.textPrimary : OpenPawTheme.textTertiary)
                        .disabled(!session.isAlive)
                        .accessibilityLabel(
                            session.isAlive
                                ? "Attach to \(session.name)"
                                : "Attach to \(session.name), unavailable because the session is dead")
                    Button("Rename") {
                        renameText = session.name
                        renamingID = session.id
                    }
                    .buttonStyle(.plain)
                    .font(OpenPawTheme.Machine.label)
                    .frame(minHeight: 44)
                    .foregroundStyle(OpenPawTheme.textSecondary)
                    .accessibilityLabel("Rename \(session.name)")
                    Button("Kill") { pendingKill = session }
                        .buttonStyle(.plain)
                        .font(OpenPawTheme.Machine.label)
                        .frame(minHeight: 44)
                        .foregroundStyle(OpenPawTheme.bad)
                        .accessibilityLabel("Kill \(session.name)")
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(OpenPawTheme.Space.medium)
        .background(OpenPawTheme.well)
        .overlay(Rectangle().stroke(OpenPawTheme.line, lineWidth: OpenPawTheme.hairline))
    }

    private var killBinding: Binding<Bool> {
        Binding(get: { pendingKill != nil }, set: { if !$0 { pendingKill = nil } })
    }
}

#Preview("Sessions") {
    NavigationStack {
        SessionListView(model: PreviewBackend.model(.populated))
    }
    .preferredColorScheme(.dark)
}

#Preview("No sessions") {
    NavigationStack {
        SessionListView(model: PreviewBackend.model(.empty))
    }
    .preferredColorScheme(.dark)
}
