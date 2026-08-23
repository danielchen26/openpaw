import OpenPawProtocol
import SwiftUI

/// The queue of things an agent needs a human for. This is why the app exists.
///
/// Ordering belongs to the model — `pendingInbox` sorts risk first, then oldest — and this screen never re-sorts.
/// Grouping by session is presentational only: a session appears at the position of its most urgent item, so the
/// top of the screen is always the next decision rather than the newest noise.
///
/// The screen owns no navigation of its own. It expects to be pushed inside the shell's `NavigationStack`, which
/// is what lets a row's `NavigationLink` reach `InboxItemDetailView` without this view knowing anything about the
/// rest of the app.
public struct InboxView: View {
    private let model: OpenPawModel

    @State private var filter: InboxCategory?
    @State private var showsDecided = false
    @State private var recovery: InboxItem?

    public init(model: OpenPawModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(OpenPawTheme.line)
            queue
        }
        .background(OpenPawTheme.ink)
        .sheet(item: $recovery) { item in
            ApprovalSheet(model: model, item: item)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: OpenPawTheme.Space.medium) {
            countBadge
            Spacer(minLength: OpenPawTheme.Space.small)
            #if os(macOS)
                reloadButton
            #endif
            filterMenu
        }
        .padding(.horizontal, OpenPawTheme.Space.large)
        .padding(.vertical, OpenPawTheme.Space.small)
    }

    private var countBadge: some View {
        HStack(spacing: OpenPawTheme.Space.small) {
            Text("pending").microLabel(OpenPawTheme.textSecondary)
            Text(badgeCount)
                .font(OpenPawTheme.Machine.headline)
                .monospacedDigit()
                .foregroundStyle(OpenPawTheme.textPrimary)
        }
        .padding(.horizontal, OpenPawTheme.Space.small)
        .padding(.vertical, OpenPawTheme.Space.tight)
        .background(OpenPawTheme.panel, in: RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card)
                .strokeBorder(OpenPawTheme.line, lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(badgeAccessibilityLabel)
    }

    /// Filtered counts read `shown of total`, so narrowing the list never hides how much work is left.
    private var badgeCount: String {
        let total = model.pendingInbox.count
        guard filter != nil else { return "\(total)" }
        return "\(pending.count) of \(total)"
    }

    private var badgeAccessibilityLabel: String {
        let total = model.pendingInbox.count
        guard let filter else { return "\(total) items pending" }
        return "\(pending.count) of \(total) pending items shown, filtered to \(InboxCopy.title(for: filter))"
    }

    #if os(macOS)
        /// The Mac has no pull gesture, so the refresh `.refreshable` provides on iOS needs a control here.
        private var reloadButton: some View {
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OpenPawTheme.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reload the inbox")
        }
    #endif

    private var filterMenu: some View {
        Menu {
            Button {
                filter = nil
            } label: {
                Label(
                    "All categories (\(model.pendingInbox.count))",
                    systemImage: filter == nil ? "checkmark" : "line.3.horizontal.decrease"
                )
            }
            ForEach(InboxCategory.allCases, id: \.self) { category in
                Button {
                    filter = category
                } label: {
                    Label(
                        "\(InboxCopy.title(for: category)) (\(count(of: category)))",
                        systemImage: filter == category ? "checkmark" : OpenPawTheme.glyph(for: category)
                    )
                }
            }
        } label: {
            HStack(spacing: OpenPawTheme.Space.tight) {
                Image(systemName: filter.map(OpenPawTheme.glyph(for:)) ?? "line.3.horizontal.decrease")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(filterTint)
                Text(filter.map(InboxCopy.title(for:)) ?? "all").microLabel(filterTint)
                #if os(iOS)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(OpenPawTheme.textTertiary)
                #endif
            }
            .padding(.horizontal, OpenPawTheme.Space.small)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Filter by category")
    }

    private var filterTint: Color {
        filter.map(OpenPawTheme.color(for:)) ?? OpenPawTheme.textSecondary
    }

    // MARK: - Queue

    private var queue: some View {
        List {
            if groups.isEmpty {
                emptySection
            } else {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.items) { item in
                            pendingRow(item, in: group)
                        }
                    } header: {
                        sessionHeader(group)
                    }
                    .textCase(nil)
                }
            }
            if !decided.isEmpty {
                decidedSection
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(OpenPawTheme.ink)
        .environment(\.defaultMinListRowHeight, 44)
        .refreshable { await model.refresh() }
    }

    private func pendingRow(_ item: InboxItem, in group: InboxSessionGroup) -> some View {
        NavigationLink {
            InboxItemDetailView(model: model, item: item)
        } label: {
            InboxQueueRow(item: item)
        }
        .listRowBackground(OpenPawTheme.ink)
        .listRowSeparatorTint(OpenPawTheme.line)
        .listRowInsets(rowInsets)
        .accessibilityIdentifier("inbox.item.\(item.id.rawValue)")
        // This exact row owns horizontal drags for Deny/Dismiss. The root pager observes the same touch but the
        // marker makes the policy refuse it, and `allowsFullSwipe: false` keeps Deny a two-step decision.
        .destinationSwipeExclusion(.inboxRowAction)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if item.actions.contains(.deny) {
                Button {
                    deny(item)
                } label: {
                    Label("Deny", systemImage: "hand.raised.slash")
                }
                .tint(OpenPawTheme.bad)
            }
            Button {
                model.dismiss(item)
            } label: {
                Label("Dismiss", systemImage: "archivebox")
            }
            .tint(OpenPawTheme.textTertiary)
        }
    }

    /// The group's identity: the human name of the work over the machine facts that pin it down. The session name
    /// lives here rather than on every row — repeating it under each of four rows was noise, and a row inside a
    /// labelled group does not need to restate its own group.
    private func sessionHeader(_ group: InboxSessionGroup) -> some View {
        let summary = model.session(group.sessionID)
        let agent = summary?.agent ?? group.items.first?.agent
        return VStack(alignment: .leading, spacing: OpenPawTheme.Space.hair) {
            HStack(alignment: .firstTextBaseline, spacing: OpenPawTheme.Space.small) {
                Text(sessionTitle(for: group.sessionID))
                    .microLabel(OpenPawTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: OpenPawTheme.Space.small)
                if let state = summary?.state {
                    Text(state.rawValue)
                        .microLabel(state == .failed ? OpenPawTheme.bad : OpenPawTheme.textTertiary)
                }
            }
            HStack(spacing: OpenPawTheme.Space.small) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(OpenPawTheme.textTertiary)
                    .accessibilityHidden(true)
                Text(agent?.displayName ?? "Agent").microLabel()
                Text("·").microLabel()
                Text(group.shortID).microLabel().lineLimit(1).truncationMode(.middle)
                if let branch = summary?.gitBranch {
                    Text("·").microLabel()
                    Text(branch).microLabel().lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.top, OpenPawTheme.Space.medium)
        .padding(.bottom, OpenPawTheme.Space.small)
        .listRowBackground(OpenPawTheme.ink)
        .listRowInsets(rowInsets)
        .listRowSeparator(.hidden)
    }

    private var decidedSection: some View {
        Section {
            if showsDecided {
                ForEach(decided) { item in
                    NavigationLink {
                        InboxItemDetailView(model: model, item: item)
                    } label: {
                        InboxDecidedRow(item: item, sessionTitle: sessionTitle(for: item.sessionID.rawValue))
                    }
                    .listRowBackground(OpenPawTheme.ink)
                    .listRowSeparatorTint(OpenPawTheme.line)
                    .listRowInsets(rowInsets)
                }
            }
        } header: {
            Button {
                showsDecided.toggle()
            } label: {
                HStack(spacing: OpenPawTheme.Space.small) {
                    Image(systemName: showsDecided ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(OpenPawTheme.textTertiary)
                        .frame(width: 12)
                    Text("already decided").microLabel(OpenPawTheme.textSecondary)
                    Text("\(decided.count)")
                        .font(OpenPawTheme.Machine.label)
                        .monospacedDigit()
                        .foregroundStyle(OpenPawTheme.textTertiary)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                showsDecided
                    ? "Hide \(decided.count) already decided items"
                    : "Show \(decided.count) already decided items"
            )
            .listRowBackground(OpenPawTheme.ink)
            .listRowInsets(rowInsets)
            .listRowSeparator(.hidden)
        }
        .textCase(nil)
    }

    private var emptySection: some View {
        Section {
            emptyState
                .frame(maxWidth: .infinity)
                .padding(.vertical, OpenPawTheme.Space.section)
                .listRowBackground(OpenPawTheme.ink)
                .listRowInsets(rowInsets)
                .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if let filter {
            EmptyStateView(
                glyph: OpenPawTheme.glyph(for: filter),
                title: "Nothing in \(InboxCopy.title(for: filter).lowercased())",
                message: "\(model.pendingInbox.count) other items are waiting. Clear the filter to see them.",
                actionTitle: "Show all categories",
                action: { self.filter = nil }
            )
        } else if model.backend == nil {
            EmptyStateView(
                glyph: "point.3.connected.trianglepath.dotted",
                title: "No host connected",
                message: "Your agents run on your own machine. Pair a host and connect it, and everything they "
                    + "need a decision on arrives here."
            )
        } else {
            EmptyStateView(
                glyph: "checkmark.seal",
                title: "The queue is clear",
                message: "When an agent needs you — a command to approve, a question to answer, a plan to sign "
                    + "off — it lands here, most dangerous first. Start work in a session and check back."
            )
        }
    }

    // MARK: - Derived state

    private var pending: [InboxItem] {
        guard let filter else { return model.pendingInbox }
        return model.pendingInbox.filter { $0.category == filter }
    }

    private var decided: [InboxItem] {
        model.inbox
            .filter { $0.status != .pending }
            .filter { filter == nil || $0.category == filter }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Buckets the already-ordered queue by session, keeping each session at the position of its first — that is,
    /// its most urgent — item.
    private var groups: [InboxSessionGroup] {
        var order: [String] = []
        var buckets: [String: [InboxItem]] = [:]
        for item in pending {
            let key = item.sessionID.rawValue
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
        }
        return order.map { InboxSessionGroup(sessionID: $0, items: buckets[$0] ?? []) }
    }

    private func count(of category: InboxCategory) -> Int {
        model.pendingInbox.reduce(into: 0) { $0 += $1.category == category ? 1 : 0 }
    }

    /// The human name of the work an item came out of. Falls back to the working directory's leaf rather than to
    /// the session id, which the group header already carries in full.
    private func sessionTitle(for sessionID: String) -> String {
        let summary = model.session(sessionID)
        if let title = summary?.title, !title.isEmpty { return title }
        if let cwd = summary?.cwd, let leaf = cwd.split(separator: "/").last, !leaf.isEmpty {
            return String(leaf)
        }
        return "untitled session"
    }

    private var rowInsets: EdgeInsets {
        EdgeInsets(
            top: 0,
            leading: OpenPawTheme.Space.large,
            bottom: 0,
            trailing: OpenPawTheme.Space.large
        )
    }

    // MARK: - Actions

    /// `OpenPawModel.resolve` refuses every decision on an item whose risk demands the full command, so a swipe
    /// cannot deny a destructive request outright. Rather than leave the user with an error and no next step, the
    /// refusal opens the one screen that can complete the decision.
    private func deny(_ item: InboxItem) {
        Task {
            let sent = await model.resolve(item, action: .deny)
            if !sent { recovery = item }
        }
    }
}

// MARK: - Rows

/// One waiting decision. Category glyph leads, the machine-register title carries the request, the risk chip sits
/// under it when there is risk to state, and the age is right-aligned so a column of ages stays readable. The
/// session is the group header's job, not the row's.
struct InboxQueueRow: View {
    let item: InboxItem

    var body: some View {
        HStack(alignment: .top, spacing: OpenPawTheme.Space.medium) {
            Image(systemName: OpenPawTheme.glyph(for: item.category))
                .font(.system(size: 14))
                .foregroundStyle(OpenPawTheme.color(for: item.category))
                .frame(width: 18)
                .padding(.top, 3)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
                Text(item.title)
                    .font(OpenPawTheme.Machine.headline)
                    .foregroundStyle(OpenPawTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                if let risk = item.risk {
                    RiskChip(risk: risk, style: .inline)
                }
            }

            Spacer(minLength: OpenPawTheme.Space.small)

            RelativeTime(date: item.createdAt)
                .padding(.top, 3)
        }
        .padding(.vertical, OpenPawTheme.Space.medium)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Risk class first, then the category, then the request. Someone listening decides whether to keep listening
    /// on the first word.
    private var accessibilityLabel: String {
        var parts: [String] = []
        if let risk = item.risk {
            parts.append(OpenPawTheme.label(for: risk.riskClass))
            if risk.requiresDetailExpansion { parts.append("needs the full command") }
        }
        parts.append(InboxCopy.title(for: item.category))
        parts.append(item.title)
        parts.append(RelativeTime.short(item.createdAt))
        return parts.joined(separator: ". ")
    }
}

/// A decision that has already been made. Quieter than a pending row, and it states the outcome in words. This
/// section is flat rather than grouped, so unlike a pending row it does have to name its own session.
struct InboxDecidedRow: View {
    let item: InboxItem
    let sessionTitle: String

    var body: some View {
        HStack(alignment: .top, spacing: OpenPawTheme.Space.medium) {
            Image(systemName: OpenPawTheme.glyph(for: item.category))
                .font(.system(size: 12))
                .foregroundStyle(OpenPawTheme.textTertiary)
                .frame(width: 18)
                .padding(.top, 3)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
                Text(item.title)
                    .font(OpenPawTheme.Machine.body)
                    .foregroundStyle(OpenPawTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: OpenPawTheme.Space.small) {
                    Text(sessionTitle)
                        .microLabel()
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("·").microLabel()
                    Text(InboxCopy.outcome(for: item)).microLabel(OpenPawTheme.textSecondary)
                }
            }

            Spacer(minLength: OpenPawTheme.Space.small)

            RelativeTime(date: item.createdAt)
                .padding(.top, 2)
        }
        .padding(.vertical, OpenPawTheme.Space.small)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(InboxCopy.title(for: item.category)). \(item.title). In \(sessionTitle). "
                + InboxCopy.decision(for: item)
        )
    }
}

// MARK: - Grouping

private struct InboxSessionGroup: Identifiable {
    let sessionID: String
    let items: [InboxItem]

    var id: String { sessionID }

    /// The identifier without its `sess_<agent>-` prefix. Stripping only `sess_` leaves the agent code doubled
    /// (`cx-cx-8842`), which reads like a bug; dropping through the first hyphen gives the raw id the host was
    /// handed, which is the part that tells two sessions of the same agent apart.
    var shortID: String {
        guard sessionID.hasPrefix("sess_") else { return sessionID }
        let body = sessionID.dropFirst(5)
        guard let hyphen = body.firstIndex(of: "-") else { return String(body) }
        return String(body[body.index(after: hyphen)...])
    }
}

// MARK: - Copy

/// The words this app uses for inbox vocabulary. Sentence case, plain verbs, no filler — and one definition, so
/// the filter menu, the section eyebrows and VoiceOver never disagree about what a category is called.
enum InboxCopy {
    static func title(for category: InboxCategory) -> String {
        switch category {
        case .permission: "Permission"
        case .question: "Question"
        case .plan: "Plan"
        case .toolFailure: "Tool failure"
        case .completion: "Completion"
        case .contextWarning: "Context"
        case .rateLimit: "Rate limit"
        case .backgroundJob: "Background job"
        }
    }

    /// What the control does, stated as the thing that happens. `approveAlways` never says "always approve
    /// everything": the host scopes it to one tool at one risk class, and the label says so.
    static func title(for action: ActionID) -> String {
        switch action {
        case .approveOnce: "Approve once"
        case .approveAlways: "Always approve this tool at this risk level"
        case .deny: "Deny"
        case .denyAlways: "Always deny"
        case .answer: "Send"
        case .stop: "Stop the agent"
        case .acknowledge: "Acknowledge"
        }
    }

    static func glyph(for action: ActionID) -> String {
        switch action {
        case .approveOnce: "checkmark"
        case .approveAlways: "checkmark.shield"
        case .deny: "hand.raised.slash"
        case .denyAlways: "nosign"
        case .answer: "arrow.up"
        case .stop: "stop.fill"
        case .acknowledge: "checkmark.square"
        }
    }

    /// Short outcome for a list row.
    static func outcome(for item: InboxItem) -> String {
        let decision = item.resolution.flatMap { ActionID(rawValue: $0)?.displayName.lowercased() }
        switch item.status {
        case .pending: return "waiting for you"
        case .resolved: return decision.map { "resolved · \($0)" } ?? "resolved"
        case .dismissed: return "dismissed here"
        case .expired: return "expired"
        }
    }

    /// Full sentence for a detail screen.
    static func decision(for item: InboxItem) -> String {
        let decision = item.resolution.flatMap { ActionID(rawValue: $0)?.displayName.lowercased() }
        switch item.status {
        case .pending:
            return "Waiting for you."
        case .resolved:
            return decision.map { "Resolved: \($0)." } ?? "Resolved."
        case .dismissed:
            return "Dismissed on this device. The agent was not answered."
        case .expired:
            return "Expired before anyone decided."
        }
    }
}

// MARK: - Previews

#Preview("Inbox · destructive request waiting") {
    NavigationStack {
        InboxView(model: PreviewBackend.model(.reviewingDestructiveCommand))
    }
}

#Preview("Inbox · populated") {
    NavigationStack {
        InboxView(model: PreviewBackend.model(.populated))
    }
}

#Preview("Inbox · clear") {
    NavigationStack {
        InboxView(model: PreviewBackend.model(.empty))
    }
}

#Preview("Inbox · no host") {
    NavigationStack {
        InboxView(model: PreviewBackend.model(.disconnected))
    }
}
