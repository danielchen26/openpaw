import OpenPawProtocol
import SwiftUI

// MARK: - Status groups

/// Staged, unstaged, untracked — the three answers to "where does this change live right now".
///
/// Git's own vocabulary, because a person reading this screen already has `git status` in their head and
/// renaming the concepts would only make them translate.
public struct RepoStatusGroup: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case staged
        case unstaged
        case untracked

        public var title: String {
            switch self {
            case .staged: "Staged"
            case .unstaged: "Unstaged"
            case .untracked: "Untracked"
            }
        }

        /// What committing right now would do with these paths.
        public var explanation: String {
            switch self {
            case .staged: "Goes into the next commit."
            case .unstaged: "Changed but not queued. A commit would leave these out."
            case .untracked: "Not in git at all. A commit would not see these."
            }
        }

        /// Staged changes read against the diff's staged mode; everything else against the working tree.
        public var diffMode: DiffMode {
            switch self {
            case .staged: .staged
            case .unstaged, .untracked: .workingTree
            }
        }
    }

    public let kind: Kind
    public let entries: [StatusEntry]

    public var id: String { kind.rawValue }

    public init(kind: Kind, entries: [StatusEntry]) {
        self.kind = kind
        self.entries = entries
    }

    /// Only groups with something in them. An empty section is noise; the clean state is one sentence instead.
    public static func groups(of status: RepoStatus) -> [RepoStatusGroup] {
        [
            RepoStatusGroup(kind: .staged, entries: status.staged),
            RepoStatusGroup(kind: .unstaged, entries: status.unstaged),
            RepoStatusGroup(kind: .untracked, entries: status.untracked),
        ]
        .filter { !$0.entries.isEmpty }
    }
}

// MARK: - Repository status

/// Where a repository stands: which branch, how far from its upstream, and every path that differs from HEAD.
///
/// This is the screen a person opens before they decide whether to trust an agent's work, so every path on it
/// is one tap from the diff that explains it.
public struct RepoStatusView: View {

    @Bindable private var model: OpenPawModel
    private let repo: String
    private let openDiff: (String, DiffMode) -> Void

    @State private var status: RepoStatus?
    @State private var isLoading = false
    @State private var failure: String?

    public init(
        model: OpenPawModel,
        repo: String,
        openDiff: @escaping (String, DiffMode) -> Void
    ) {
        self._model = Bindable(model)
        self.repo = repo
        self.openDiff = openDiff
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: OpenPawTheme.Space.large) {
                if let status {
                    branchPanel(status)
                    if status.isDirty {
                        ForEach(RepoStatusGroup.groups(of: status)) { group in
                            groupSection(group)
                        }
                    } else {
                        cleanPanel(status)
                    }
                } else if let failure {
                    EmptyStateView(
                        glyph: "exclamationmark.triangle",
                        title: "The status did not load",
                        message: failure,
                        actionTitle: "Try again"
                    ) {
                        Task { await load() }
                    }
                } else {
                    EmptyStateView(
                        glyph: "arrow.triangle.branch",
                        title: "Reading \(repo)",
                        message: "OpenPaw is asking the host where this repository stands."
                    )
                }
            }
            .padding(OpenPawTheme.Space.large)
        }
        .background(OpenPawTheme.ink)
        .navigationTitle(repo)
        .refreshable { await load() }
        .task(id: repo) { await load() }
    }

    // MARK: Branch

    private func branchPanel(_ status: RepoStatus) -> some View {
        Panel(label: "Branch") {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                HStack(alignment: .firstTextBaseline, spacing: OpenPawTheme.Space.small) {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(OpenPawTheme.textSecondary)
                        .accessibilityHidden(true)
                    Text(status.branch)
                        .font(OpenPawTheme.Machine.title)
                        .foregroundStyle(OpenPawTheme.textPrimary)
                        .textSelection(.enabled)
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Refreshing the status")
                    }
                }

                HStack(spacing: OpenPawTheme.Space.xl) {
                    tracking(
                        label: "Ahead",
                        count: status.ahead,
                        glyph: "arrow.up",
                        detail: "commit\(status.ahead == 1 ? "" : "s") the upstream does not have"
                    )
                    tracking(
                        label: "Behind",
                        count: status.behind,
                        glyph: "arrow.down",
                        detail: "commit\(status.behind == 1 ? "" : "s") you do not have"
                    )
                }

                Text(summaryLine(status))
                    .font(OpenPawTheme.Human.caption)
                    .foregroundStyle(OpenPawTheme.textSecondary)
            }
        }
    }

    private func tracking(label: String, count: Int, glyph: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.hair) {
            Text(label).microLabel()
            HStack(spacing: OpenPawTheme.Space.tight) {
                Image(systemName: glyph)
                    .font(OpenPawTheme.Machine.codeSmall)
                    .accessibilityHidden(true)
                Text("\(count)")
                    .font(OpenPawTheme.Machine.headline)
            }
            .foregroundStyle(count == 0 ? OpenPawTheme.textTertiary : OpenPawTheme.textPrimary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(count) \(detail)")
    }

    private func summaryLine(_ status: RepoStatus) -> String {
        let changed = status.staged.count + status.unstaged.count + status.untracked.count
        guard changed > 0 else { return "Nothing differs from HEAD." }
        var parts: [String] = []
        if !status.staged.isEmpty { parts.append("\(status.staged.count) staged") }
        if !status.unstaged.isEmpty { parts.append("\(status.unstaged.count) unstaged") }
        if !status.untracked.isEmpty { parts.append("\(status.untracked.count) untracked") }
        return parts.joined(separator: ", ") + "."
    }

    private func cleanPanel(_ status: RepoStatus) -> some View {
        HumanPanel {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
                Text("The working tree is clean.")
                    .font(OpenPawTheme.Human.prose)
                    .foregroundStyle(OpenPawTheme.textPrimary)
                Text(
                    status.ahead > 0
                        ? "Every change is committed. \(status.ahead) commit\(status.ahead == 1 ? " is" : "s are") "
                            + "waiting to be pushed."
                        : "Every change is committed and \(status.branch) matches its upstream."
                )
                .font(OpenPawTheme.Human.caption)
                .foregroundStyle(OpenPawTheme.textSecondary)
            }
        }
    }

    // MARK: Groups

    private func groupSection(_ group: RepoStatusGroup) -> some View {
        Panel(label: group.kind.title) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(group.kind.explanation)
                        .font(OpenPawTheme.Human.caption)
                        .foregroundStyle(OpenPawTheme.textSecondary)
                    Spacer(minLength: OpenPawTheme.Space.small)
                    Text("\(group.entries.count)")
                        .font(OpenPawTheme.Machine.code)
                        .foregroundStyle(OpenPawTheme.textTertiary)
                }
                .padding(.bottom, OpenPawTheme.Space.small)

                ForEach(group.entries) { entry in
                    Button {
                        openDiff(entry.path, group.kind.diffMode)
                    } label: {
                        StatusEntryRow(entry: entry)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Copy path") { OpenPawClipboard.copy(entry.path) }
                        Button("Open diff") { openDiff(entry.path, group.kind.diffMode) }
                    }
                    .accessibilityAction(named: "Copy path") { OpenPawClipboard.copy(entry.path) }

                    if entry.id != group.entries.last?.id {
                        Divider().overlay(OpenPawTheme.line)
                    }
                }
            }
        }
    }

    // MARK: Loading

    private func load() async {
        guard let backend = model.backend else {
            failure = "No host is connected. Connect a host to read its repositories."
            return
        }
        isLoading = true
        failure = nil
        defer { isLoading = false }
        do {
            status = try await backend.repoStatus(repo)
        } catch {
            model.present(error, while: "reading the status of \(repo)")
            failure = model.lastError?.detail ?? String(describing: error)
        }
    }
}

// MARK: - Rows

struct StatusEntryRow: View {
    let entry: StatusEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: OpenPawTheme.Space.small) {
            Image(systemName: ChangeKindCopy.glyph(entry.change))
                .font(OpenPawTheme.Machine.codeSmall)
                .foregroundStyle(ChangeKindCopy.tone(entry.change))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: OpenPawTheme.Space.hair) {
                Text(RepoPath.lastSegment(entry.path))
                    .font(OpenPawTheme.Machine.body)
                    .foregroundStyle(OpenPawTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.head)
                if let parent = RepoPath.parent(entry.path) {
                    Text(parent)
                        .font(OpenPawTheme.Machine.codeSmall)
                        .foregroundStyle(OpenPawTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if let oldPath = entry.oldPath, oldPath != entry.path {
                    Text("was \(oldPath)")
                        .font(OpenPawTheme.Machine.codeSmall)
                        .foregroundStyle(OpenPawTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer(minLength: OpenPawTheme.Space.small)

            Text(ChangeKindCopy.word(entry.change))
                .microLabel(ChangeKindCopy.tone(entry.change))

            Image(systemName: "chevron.right")
                .font(OpenPawTheme.Machine.codeSmall)
                .foregroundStyle(OpenPawTheme.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, OpenPawTheme.Space.small)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(ChangeKindCopy.word(entry.change)), \(entry.path). Opens the diff.")
    }
}

// MARK: - Preview

#Preview("Repository status") {
    NavigationStack {
        RepoStatusView(
            model: PreviewBackend.model(.populated),
            repo: "openpaw",
            openDiff: { _, _ in }
        )
    }
}
