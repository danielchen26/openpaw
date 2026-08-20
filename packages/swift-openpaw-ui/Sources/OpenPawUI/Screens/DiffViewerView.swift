import OpenPawProtocol
import SwiftUI

// MARK: - Layout

/// Unified stacks removals above additions in one column; split pairs them across two.
public enum DiffLayout: String, Sendable, Hashable, CaseIterable, Identifiable {
    case unified
    case split

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .unified: "Unified"
        case .split: "Split"
        }
    }
}

// MARK: - Planned rows

/// One laid-out row of a file diff.
///
/// Rows are planned in a single pass over the hunks and handed to a `LazyVStack`, so a ten-thousand-line diff
/// costs one walk of the model and lays out only the rows the reader actually scrolled to.
public enum DiffRow: Identifiable, Sendable, Hashable {
    /// A `@@ -a,b +c,d @@` marker. Chrome, so it does not spend the line budget.
    case hunkHeader(id: String, text: String)
    case unified(id: String, line: DiffLine)
    case split(id: String, left: DiffLine?, right: DiffLine?)

    public var id: String {
        switch self {
        case .hunkHeader(let id, _), .unified(let id, _), .split(let id, _, _): id
        }
    }

    /// Hunk markers are not content, so they are not charged against the line budget.
    public var chargesBudget: Bool {
        if case .hunkHeader = self { return false }
        return true
    }
}

/// Widest line, in characters, on each side of a planned diff.
///
/// The machine register is monospaced, so padding every row to the same character count is enough to make the
/// row fills line up into one solid column — no font metrics, no pixel arithmetic, and Dynamic Type still
/// scales the whole grid.
public struct DiffColumns: Sendable, Hashable {
    public let left: Int
    public let right: Int

    public init(left: Int, right: Int) {
        self.left = left
        self.right = right
    }
}

public enum DiffRowPlanner {

    public static func rows(for file: FileDiff, layout: DiffLayout) -> [DiffRow] {
        switch layout {
        case .unified: unified(file)
        case .split: split(file)
        }
    }

    public static func unified(_ file: FileDiff) -> [DiffRow] {
        var rows: [DiffRow] = []
        rows.reserveCapacity(estimatedRowCount(file))
        for (hunkIndex, hunk) in file.hunks.enumerated() {
            rows.append(.hunkHeader(id: "h\(hunkIndex)", text: hunk.header))
            for (lineIndex, line) in hunk.lines.enumerated() {
                rows.append(.unified(id: "h\(hunkIndex)l\(lineIndex)", line: line))
            }
        }
        return rows
    }

    /// Pairing comes from `FileDiff.splitRows()`, so the app holds exactly one implementation of it. Applying it
    /// one hunk at a time preserves the `@@` markers, which are the only location information a split view
    /// would otherwise lose.
    public static func split(_ file: FileDiff) -> [DiffRow] {
        var rows: [DiffRow] = []
        rows.reserveCapacity(estimatedRowCount(file))
        for (hunkIndex, hunk) in file.hunks.enumerated() {
            rows.append(.hunkHeader(id: "h\(hunkIndex)", text: hunk.header))
            let isolated = FileDiff(path: file.path, change: file.change, hunks: [hunk])
            for (rowIndex, pair) in isolated.splitRows().enumerated() {
                rows.append(.split(id: "h\(hunkIndex)r\(rowIndex)", left: pair.left, right: pair.right))
            }
        }
        return rows
    }

    /// Characters the line-number gutter must print, so the columns line up across every hunk in the file.
    public static func gutterWidth(for file: FileDiff) -> Int {
        var widest: UInt32 = 0
        for hunk in file.hunks {
            widest = max(widest, hunk.oldStart + hunk.oldLines)
            widest = max(widest, hunk.newStart + hunk.newLines)
        }
        return max(2, String(widest).count)
    }

    /// Computed once over the whole planned set, so the grid width never shifts while the reader scrolls.
    public static func columns(in rows: [DiffRow]) -> DiffColumns {
        var left = 0
        var right = 0
        for row in rows {
            switch row {
            case .hunkHeader:
                continue
            case .unified(_, let line):
                left = max(left, line.text.count)
            case .split(_, let leftLine, let rightLine):
                if let leftLine { left = max(left, leftLine.text.count) }
                if let rightLine { right = max(right, rightLine.text.count) }
            }
        }
        return DiffColumns(left: max(40, left), right: max(40, right))
    }

    private static func estimatedRowCount(_ file: FileDiff) -> Int {
        file.hunks.reduce(0) { $0 + $1.lines.count + 1 }
    }
}

// MARK: - Line budget

/// A hard cap on how many lines one file renders.
///
/// A lockfile or a vendored bundle can be a hundred thousand lines. Laying all of it out to serve a reader who
/// will look at the first screenful is a bad trade, so the cap is explicit and its remainder is stated rather
/// than silently dropped.
public struct LineBudget: Sendable, Hashable {
    /// Diffs: larger than any review-sized change, small enough that the first frame is immediate.
    public static let diff = LineBudget(limit: 1_200)
    /// Blobs: a file longer than this is being skimmed, not read.
    public static let blob = LineBudget(limit: 2_000)

    public let limit: Int

    public init(limit: Int) {
        self.limit = max(0, limit)
    }

    /// Keeps the leading rows up to `limit` chargeable rows, and reports how many were withheld.
    public func apply<Row>(to rows: [Row], charges: (Row) -> Bool = { _ in true }) -> Budgeted<Row> {
        var kept: [Row] = []
        kept.reserveCapacity(min(rows.count, limit))
        var rendered = 0
        var total = 0
        for row in rows {
            let costs = charges(row)
            if costs { total += 1 }
            guard rendered < limit else { continue }
            kept.append(row)
            if costs { rendered += 1 }
        }
        return Budgeted(rows: kept, rendered: rendered, total: total, limit: limit)
    }
}

/// The result of applying a `LineBudget`: what is on screen, and what is not.
public struct Budgeted<Row> {
    public let rows: [Row]
    public let rendered: Int
    public let total: Int
    public let limit: Int

    public init(rows: [Row], rendered: Int, total: Int, limit: Int) {
        self.rows = rows
        self.rendered = rendered
        self.total = total
        self.limit = limit
    }

    public var withheld: Int { max(0, total - rendered) }
    public var isTruncated: Bool { withheld > 0 }

    /// Says the number out loud. "Truncated" on its own tells a reviewer nothing about what they are missing.
    public var note: String? {
        guard isTruncated else { return nil }
        return "Showing first \(rendered) lines of \(total). \(withheld) more are not rendered."
    }
}

// MARK: - Patch text

/// Rebuilds a `git apply`-able patch from a `FileDiff`, so `Copy patch` yields something a person can paste
/// into a terminal instead of a transcription of what they saw on a screen.
public enum UnifiedPatch {

    public static func text(for file: FileDiff) -> String {
        let old = file.oldPath ?? file.path
        var out = "diff --git a/\(old) b/\(file.path)\n"
        if file.change == .renamed, let oldPath = file.oldPath {
            out += "rename from \(oldPath)\nrename to \(file.path)\n"
        }
        if file.change == .copied, let oldPath = file.oldPath {
            out += "copy from \(oldPath)\ncopy to \(file.path)\n"
        }
        guard !file.binary else {
            return out + "Binary files a/\(old) and b/\(file.path) differ\n"
        }
        switch file.change {
        case .added:
            out += "--- /dev/null\n+++ b/\(file.path)\n"
        case .deleted:
            out += "--- a/\(old)\n+++ /dev/null\n"
        case .modified, .renamed, .copied, .typeChanged:
            out += "--- a/\(old)\n+++ b/\(file.path)\n"
        }
        for hunk in file.hunks {
            if hunk.header.hasPrefix("@@") {
                out += hunk.header + "\n"
            } else {
                out += "@@ -\(hunk.oldStart),\(hunk.oldLines) +\(hunk.newStart),\(hunk.newLines) @@"
                out += hunk.header.isEmpty ? "\n" : " \(hunk.header)\n"
            }
            for line in hunk.lines {
                switch line.kind {
                case .context: out += " \(line.text)\n"
                case .added: out += "+\(line.text)\n"
                case .removed: out += "-\(line.text)\n"
                case .noNewline: out += "\\ No newline at end of file\n"
                }
            }
        }
        return out
    }

    public static func text(for diff: Diff) -> String {
        diff.files.map(text(for:)).joined()
    }
}

// MARK: - Shared vocabulary for the repository screens

/// Path arithmetic on the host's POSIX paths. Deliberately not a `String` extension: this module is assembled
/// from several slices, and a name as generic as `parent` on `String` belongs to nobody.
enum RepoPath {

    static func lastSegment(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    static func parent(_ path: String) -> String? {
        var parts = path.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return nil }
        parts.removeLast()
        return parts.joined(separator: "/")
    }

    static func join(_ base: String, _ name: String) -> String {
        base.isEmpty ? name : "\(base)/\(name)"
    }
}

enum ChangeKindCopy {

    static func glyph(_ kind: ChangeKind) -> String {
        switch kind {
        case .added: "plus.circle"
        case .modified: "pencil"
        case .deleted: "minus.circle"
        case .renamed: "arrow.forward.square"
        case .copied: "doc.on.doc"
        case .typeChanged: "arrow.triangle.2.circlepath"
        }
    }

    static func word(_ kind: ChangeKind) -> String {
        switch kind {
        case .added: "added"
        case .modified: "modified"
        case .deleted: "deleted"
        case .renamed: "renamed"
        case .copied: "copied"
        case .typeChanged: "type changed"
        }
    }

    /// The diff ramp for the two kinds that mean gain and loss, desaturated chrome for the rest: the saturated
    /// end of the palette belongs to risk, and nothing on these screens can execute anything.
    static func tone(_ kind: ChangeKind) -> Color {
        switch kind {
        case .added: OpenPawTheme.diffAddedText
        case .deleted: OpenPawTheme.diffRemovedText
        case .modified, .renamed, .copied: OpenPawTheme.textSecondary
        case .typeChanged: OpenPawTheme.warn
        }
    }
}

enum DiffModeCopy {

    static func title(_ mode: DiffMode) -> String {
        switch mode {
        case .workingTree: "Working tree"
        case .staged: "Staged"
        case .commit(let commit): "Commit \(shorten(commit))"
        case .range(let base, let head): "\(shorten(base))..\(shorten(head))"
        }
    }

    static func subtitle(_ mode: DiffMode) -> String {
        switch mode {
        case .workingTree: "Everything not yet staged"
        case .staged: "Everything staged for the next commit"
        case .commit: "That commit against its parent"
        case .range: "Head against base"
        }
    }

    static func shorten(_ ref: String) -> String {
        let isHex = ref.count >= 12 && ref.allSatisfy(\.isHexDigit)
        return isHex ? String(ref.prefix(8)) : ref
    }
}

/// A glyph and a word, sized to a real touch target.
struct RepoActionButton: View {
    let title: String
    let glyph: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: OpenPawTheme.Space.tight) {
                Image(systemName: glyph)
                Text(title)
            }
            .font(OpenPawTheme.Machine.label)
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(OpenPawTheme.textSecondary)
            .padding(.horizontal, OpenPawTheme.Space.small)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension View {
    /// Refs, paths and search terms are never sentences: no capitalisation, no autocorrect.
    func repoTextInput() -> some View {
        #if os(iOS)
        return textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        return autocorrectionDisabled()
        #endif
    }
}

// MARK: - Diff viewer

/// The screen a reviewer lives in: which files an agent touched, and what it did to the one they picked.
///
/// Everything here is read-only. Nothing on this screen can change the working tree, which is why it carries no
/// risk colour of its own.
public struct DiffViewerView: View {

    @Bindable private var model: OpenPawModel
    private let repo: String
    private let budget: LineBudget
    private let openInFileBrowser: (String) -> Void

    @State private var mode: DiffMode
    @State private var layout: DiffLayout
    @State private var diff: Diff?
    @State private var selectedPath: String?
    @State private var isLoading = false
    @State private var failure: String?
    @State private var refPrompt: DiffRefPrompt?

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var sizeClassIsCompact: Bool { horizontalSizeClass == .compact }
    #else
    private var sizeClassIsCompact: Bool { false }
    #endif

    /// Below this, a file list beside a diff leaves neither one readable: the list needs its 320 points and a
    /// diff column narrower than about 380 wraps or scrolls for every line.
    static let splitMinimumWidth: CGFloat = 720

    /// Width decides, with the iOS size class as a second opinion.
    ///
    /// A size-class-only rule was wrong twice over: `horizontalSizeClass` does not exist on macOS, so every
    /// headless render took the wide branch and photographed a two-pane squeeze at phone width, and a Mac window
    /// dragged narrow kept a split it could not afford. Width is what actually decides, and it is the same
    /// number on every platform.
    static func prefersCompact(width: CGFloat, sizeClassIsCompact: Bool) -> Bool {
        sizeClassIsCompact || width < splitMinimumWidth
    }

    /// `layout` is injectable rather than always starting unified, because a deep link into a review and a snapshot
    /// run both need to open on a specific presentation, and a screen whose presentation cannot be addressed from
    /// outside cannot be verified from outside either.
    public init(
        model: OpenPawModel,
        repo: String,
        mode: DiffMode = .workingTree,
        layout: DiffLayout = .unified,
        focusPath: String? = nil,
        budget: LineBudget = .diff,
        openInFileBrowser: @escaping (String) -> Void
    ) {
        self._model = Bindable(model)
        self.repo = repo
        self.budget = budget
        self.openInFileBrowser = openInFileBrowser
        self._mode = State(initialValue: mode)
        self._layout = State(initialValue: layout)
        self._selectedPath = State(initialValue: focusPath)
    }

    public var body: some View {
        VStack(spacing: 0) {
            controls
            Divider().overlay(OpenPawTheme.line)
            content
        }
        .background(OpenPawTheme.ink)
        .navigationTitle(repo)
        .task(id: DiffLoadKey(repo: repo, mode: mode)) { await load() }
        .sheet(item: $refPrompt) { prompt in
            DiffRefSheet(prompt: prompt) { newMode in
                mode = newMode
                refPrompt = nil
            } onCancel: {
                refPrompt = nil
            }
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
            HStack(spacing: OpenPawTheme.Space.medium) {
                modeMenu
                layoutToggle
                Spacer(minLength: OpenPawTheme.Space.small)
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Loading the diff")
                }
                totals
            }
            Text(DiffModeCopy.subtitle(mode))
                .font(OpenPawTheme.Human.caption)
                .foregroundStyle(OpenPawTheme.textTertiary)
        }
        .padding(.horizontal, OpenPawTheme.Space.large)
        .padding(.vertical, OpenPawTheme.Space.small)
    }

    private var modeMenu: some View {
        Menu {
            Button("Working tree") { mode = .workingTree }
            Button("Staged") { mode = .staged }
            Divider()
            Button("Commit…") { refPrompt = DiffRefPrompt(kind: .commit) }
            Button("Branch range…") { refPrompt = DiffRefPrompt(kind: .range) }
        } label: {
            HStack(spacing: OpenPawTheme.Space.tight) {
                Text(DiffModeCopy.title(mode))
                    .font(OpenPawTheme.Machine.headline)
                    .foregroundStyle(OpenPawTheme.textPrimary)
                Image(systemName: "chevron.down")
                    .font(OpenPawTheme.Machine.codeSmall)
                    .foregroundStyle(OpenPawTheme.textTertiary)
            }
            .padding(.horizontal, OpenPawTheme.Space.small)
            .frame(minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card)
                    .fill(OpenPawTheme.panel)
            )
        }
        .accessibilityLabel("Comparison, currently \(DiffModeCopy.title(mode))")
    }

    private var layoutToggle: some View {
        Picker("Diff layout", selection: $layout) {
            ForEach(DiffLayout.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 190)
        .accessibilityLabel("Diff layout, currently \(layout.title)")
    }

    @ViewBuilder private var totals: some View {
        if let diff, !diff.files.isEmpty {
            HStack(spacing: OpenPawTheme.Space.small) {
                Text("+\(diff.additions)")
                    .foregroundStyle(OpenPawTheme.diffAddedText)
                Text("−\(diff.deletions)")
                    .foregroundStyle(OpenPawTheme.diffRemovedText)
                Text("\(diff.files.count) file\(diff.files.count == 1 ? "" : "s")")
                    .foregroundStyle(OpenPawTheme.textTertiary)
            }
            .font(OpenPawTheme.Machine.code)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(diff.additions) added, \(diff.deletions) removed, across \(diff.files.count) files"
            )
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let failure {
            EmptyStateView(
                glyph: "exclamationmark.triangle",
                title: "The diff did not load",
                message: failure,
                actionTitle: "Try again"
            ) {
                Task { await load() }
            }
        } else if let diff {
            if diff.files.isEmpty {
                EmptyStateView(
                    glyph: "equal.circle",
                    title: emptyTitle,
                    message: emptyMessage,
                    actionTitle: "Check again"
                ) {
                    Task { await load() }
                }
            } else {
                GeometryReader { proxy in
                    if Self.prefersCompact(
                        width: proxy.size.width,
                        sizeClassIsCompact: sizeClassIsCompact
                    ) {
                        compactList(diff)
                    } else {
                        sideBySidePanes(diff)
                    }
                }
            }
        } else {
            EmptyStateView(
                glyph: "arrow.triangle.branch",
                title: "Reading the diff",
                message: "OpenPaw is asking \(repo) what changed."
            )
        }
    }

    private var emptyTitle: String {
        switch mode {
        case .workingTree: "The working tree is clean"
        case .staged: "Nothing is staged"
        case .commit, .range: "These revisions are identical"
        }
    }

    private var emptyMessage: String {
        switch mode {
        case .workingTree:
            "No file differs from the index. Switch to Staged to see what is queued to commit."
        case .staged:
            "Nothing is queued for the next commit. Switch to Working tree to see uncommitted edits."
        case .commit:
            "That commit changed no tracked file."
        case .range:
            "Head and base point at the same tree."
        }
    }

    /// iPhone: the file list is the screen and the diff is a push. A 390-point split is unreadable.
    private func compactList(_ diff: Diff) -> some View {
        List {
            Section {
                ForEach(diff.files) { file in
                    NavigationLink(value: DiffFileRoute(path: file.path)) {
                        DiffFileListRow(file: file, isSelected: false)
                    }
                    .listRowBackground(OpenPawTheme.panel)
                    .listRowSeparatorTint(OpenPawTheme.line)
                }
            } header: {
                Text("Files").microLabel()
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(OpenPawTheme.ink)
        .navigationDestination(for: DiffFileRoute.self) { route in
            if let file = diff.files.first(where: { $0.path == route.path }) {
                DiffFilePane(
                    file: file,
                    layout: layout,
                    budget: budget,
                    openInFileBrowser: openInFileBrowser
                )
                .background(OpenPawTheme.ink)
                .navigationTitle(RepoPath.lastSegment(route.path))
            } else {
                EmptyStateView(
                    glyph: "questionmark.folder",
                    title: "That file left the diff",
                    message: "The comparison reloaded and \(route.path) is unchanged now. "
                        + "Go back to the file list."
                )
            }
        }
    }

    /// iPad and Mac: list and diff at once, which is how a reviewer actually works.
    private func sideBySidePanes(_ diff: Diff) -> some View {
        // Resolved once. Asking per row would make the list quadratic in the number of changed files.
        let selected = selection(in: diff)

        return HStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text("Files").microLabel()
                        .padding(.horizontal, OpenPawTheme.Space.medium)
                        .padding(.vertical, OpenPawTheme.Space.small)
                    ForEach(diff.files) { file in
                        Button {
                            selectedPath = file.path
                        } label: {
                            DiffFileListRow(file: file, isSelected: file.path == selected)
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(OpenPawTheme.line)
                    }
                }
            }
            .frame(width: 320)
            .background(OpenPawTheme.panel)

            Divider().overlay(OpenPawTheme.lineStrong)

            if let selected, let file = diff.files.first(where: { $0.path == selected }) {
                DiffFilePane(
                    file: file,
                    layout: layout,
                    budget: budget,
                    openInFileBrowser: openInFileBrowser
                )
            } else {
                EmptyStateView(
                    glyph: "sidebar.left",
                    title: "Pick a file",
                    message: "The list on the left is every file this comparison touched."
                )
            }
        }
    }

    private func selection(in diff: Diff) -> String? {
        if let selectedPath, diff.files.contains(where: { $0.path == selectedPath }) {
            return selectedPath
        }
        return diff.files.first?.path
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
            diff = try await backend.diff(repo: repo, mode: mode, path: nil)
        } catch {
            model.present(error, while: "loading the diff for \(repo)")
            failure = model.lastError?.detail ?? String(describing: error)
        }
    }
}

/// Reload key: repo and comparison together, so switching either refetches exactly once.
struct DiffLoadKey: Hashable, Sendable {
    let repo: String
    let mode: DiffMode
}

/// Push target for the compact file list.
struct DiffFileRoute: Hashable, Sendable {
    let path: String
}

// MARK: - File list row

struct DiffFileListRow: View {
    let file: FileDiff
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: OpenPawTheme.Space.small) {
            Image(systemName: ChangeKindCopy.glyph(file.change))
                .font(OpenPawTheme.Machine.codeSmall)
                .foregroundStyle(ChangeKindCopy.tone(file.change))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: OpenPawTheme.Space.hair) {
                Text(RepoPath.lastSegment(file.path))
                    .font(OpenPawTheme.Machine.body)
                    .foregroundStyle(OpenPawTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.head)
                if let parent = RepoPath.parent(file.path) {
                    Text(parent)
                        .font(OpenPawTheme.Machine.codeSmall)
                        .foregroundStyle(OpenPawTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if let oldPath = file.oldPath, oldPath != file.path {
                    Text("was \(oldPath)")
                        .font(OpenPawTheme.Machine.codeSmall)
                        .foregroundStyle(OpenPawTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer(minLength: OpenPawTheme.Space.small)

            if file.binary {
                Text("binary")
                    .font(OpenPawTheme.Machine.codeSmall)
                    .foregroundStyle(OpenPawTheme.textTertiary)
            } else {
                HStack(spacing: OpenPawTheme.Space.tight) {
                    Text("+\(file.additions)").foregroundStyle(OpenPawTheme.diffAddedText)
                    Text("−\(file.deletions)").foregroundStyle(OpenPawTheme.diffRemovedText)
                }
                .font(OpenPawTheme.Machine.codeSmall)
            }
        }
        .padding(.horizontal, OpenPawTheme.Space.medium)
        .padding(.vertical, OpenPawTheme.Space.small)
        .frame(minHeight: 44)
        .background(isSelected ? OpenPawTheme.well : Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenLabel)
    }

    private var spokenLabel: String {
        var parts = ["\(file.path), \(ChangeKindCopy.word(file.change))"]
        if file.binary {
            parts.append("binary file")
        } else {
            parts.append("\(file.additions) added, \(file.deletions) removed")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - One file's diff

struct DiffFilePane: View {
    let file: FileDiff
    let layout: DiffLayout
    let budget: LineBudget
    let openInFileBrowser: (String) -> Void

    @State private var didCopyPatch = false

    private var language: SyntaxLanguage { SyntaxHighlighter.language(forPath: file.path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(OpenPawTheme.line)
            if file.binary {
                binaryNotice
            } else if file.hunks.isEmpty {
                EmptyStateView(
                    glyph: "doc",
                    title: "No text changed",
                    message: "Git reports this file as \(ChangeKindCopy.word(file.change)) with no line "
                        + "changes. Its mode or metadata moved instead."
                )
            } else {
                grid
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
            HStack(alignment: .firstTextBaseline, spacing: OpenPawTheme.Space.small) {
                Image(systemName: ChangeKindCopy.glyph(file.change))
                    .foregroundStyle(ChangeKindCopy.tone(file.change))
                    .accessibilityHidden(true)
                Text(file.path)
                    .font(OpenPawTheme.Machine.headline)
                    .foregroundStyle(OpenPawTheme.textPrimary)
                    .textSelection(.enabled)
            }

            Text(totalsLine)
                .font(OpenPawTheme.Machine.code)
                .foregroundStyle(OpenPawTheme.textSecondary)

            HStack(spacing: OpenPawTheme.Space.small) {
                RepoActionButton(
                    title: didCopyPatch ? "Patch copied" : "Copy patch",
                    glyph: didCopyPatch ? "checkmark" : "doc.on.clipboard"
                ) {
                    OpenPawClipboard.copy(UnifiedPatch.text(for: file))
                    didCopyPatch = true
                }
                RepoActionButton(title: "Open in file browser", glyph: "folder") {
                    openInFileBrowser(file.path)
                }
            }
        }
        .padding(.horizontal, OpenPawTheme.Space.large)
        .padding(.vertical, OpenPawTheme.Space.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OpenPawTheme.panel)
        .onChange(of: file.path) { _, _ in didCopyPatch = false }
    }

    private var totalsLine: String {
        var parts: [String] = [ChangeKindCopy.word(file.change)]
        if file.binary {
            parts.append("binary")
        } else {
            parts.append("+\(file.additions)")
            parts.append("−\(file.deletions)")
            parts.append("\(file.hunks.count) hunk\(file.hunks.count == 1 ? "" : "s")")
        }
        if let oldPath = file.oldPath, oldPath != file.path {
            parts.append("from \(oldPath)")
        }
        return parts.joined(separator: "  ·  ")
    }

    private var binaryNotice: some View {
        Panel(label: "Binary") {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
                Text("This file is binary.")
                    .font(OpenPawTheme.Human.prose)
                    .foregroundStyle(OpenPawTheme.textPrimary)
                Text(
                    "Git reports it as \(ChangeKindCopy.word(file.change)) and has no lines to show. "
                        + "OpenPaw does not render raw bytes."
                )
                .font(OpenPawTheme.Human.caption)
                .foregroundStyle(OpenPawTheme.textSecondary)
                RepoActionButton(title: "Open in file browser", glyph: "folder") {
                    openInFileBrowser(file.path)
                }
            }
        }
        .padding(OpenPawTheme.Space.large)
    }

    /// Half the pane, less the divider between the sides, so the two columns fill the width evenly without
    /// overflowing into a scroll extent the reader did not earn.
    static func sideWidth(in paneWidth: CGFloat) -> CGFloat {
        max(0, (paneWidth - OpenPawTheme.Space.hair) / 2)
    }

    private var grid: some View {
        let planned = DiffRowPlanner.rows(for: file, layout: layout)
        let capped = budget.apply(to: planned) { $0.chargesBudget }
        let columns = DiffRowPlanner.columns(in: capped.rows)
        let gutter = DiffRowPlanner.gutterWidth(for: file)

        return VStack(alignment: .leading, spacing: 0) {
            GeometryReader { proxy in
                // Two single-axis scroll views, never one two-axis view. `ScrollView([.horizontal, .vertical])`
                // proposes its own viewport size to the content and centres anything smaller than it, which
                // vertically centred the grid and squeezed both columns until code wrapped mid-token. Nested
                // single-axis views top-anchor and propose an unspecified width, so each line takes its ideal
                // width and the reader scrolls to reach the rest.
                ScrollView(.vertical) {
                    ScrollView(.horizontal) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(capped.rows) { row in
                                switch row {
                                case .hunkHeader(_, let text):
                                    DiffHunkHeaderRow(text: text, width: proxy.size.width)
                                case .unified(_, let line):
                                    DiffUnifiedRow(
                                        line: line,
                                        language: language,
                                        gutterWidth: gutter,
                                        columns: columns.left,
                                        rowWidth: proxy.size.width
                                    )
                                case .split(_, let left, let right):
                                    DiffSplitRow(
                                        left: left,
                                        right: right,
                                        language: language,
                                        gutterWidth: gutter,
                                        columns: columns,
                                        sideWidth: Self.sideWidth(in: proxy.size.width)
                                    )
                                }
                            }
                        }
                        .textSelection(.enabled)
                        .padding(.vertical, OpenPawTheme.Space.small)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(OpenPawTheme.well)
            }

            if let note = capped.note {
                HStack(spacing: OpenPawTheme.Space.small) {
                    Image(systemName: "scissors").accessibilityHidden(true)
                    Text(note)
                }
                .font(OpenPawTheme.Machine.codeSmall)
                .foregroundStyle(OpenPawTheme.warn)
                .padding(.horizontal, OpenPawTheme.Space.large)
                .padding(.vertical, OpenPawTheme.Space.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(OpenPawTheme.panel)
            }
        }
    }
}

// MARK: - Diff rows

struct DiffHunkHeaderRow: View {
    let text: String
    let width: CGFloat

    var body: some View {
        Text(text.isEmpty ? "@@" : text)
            .font(OpenPawTheme.Machine.codeSmall)
            .foregroundStyle(OpenPawTheme.textTertiary)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, OpenPawTheme.Space.small)
            .padding(.vertical, OpenPawTheme.Space.tight)
            .frame(minWidth: width, alignment: .leading)
            .background(OpenPawTheme.panel)
    }
}

struct DiffUnifiedRow: View {
    let line: DiffLine
    let language: SyntaxLanguage
    let gutterWidth: Int
    let columns: Int
    let rowWidth: CGFloat

    var body: some View {
        // The gutter is a smaller style than the code beside it, so the row aligns on the text baseline. Centre
        // alignment would drift the digits off the code as Dynamic Type scales the two styles apart.
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            DiffGutterCell(value: line.oldLine, width: gutterWidth)
            DiffGutterCell(value: line.newLine, width: gutterWidth)
            Text(DiffLineText.marker(for: line.kind))
                .font(OpenPawTheme.Machine.code)
                .foregroundStyle(DiffLineText.markerTone(for: line.kind))
            DiffCodeText(line: line, language: language, columns: columns)
        }
        .padding(.vertical, OpenPawTheme.Space.hair)
        // Fills the pane so the row tint reads as a band, and never shrinks below the code it carries.
        .frame(minWidth: rowWidth, alignment: .leading)
        .background(DiffLineText.fill(for: line.kind))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(DiffLineText.spokenLabel(line))
    }
}

/// Both sides live inside the single horizontal scroll view that `DiffFilePane` puts around the grid, so their
/// offsets are locked together by construction — there is no offset to plumb and no way for them to drift.
struct DiffSplitRow: View {
    let left: DiffLine?
    let right: DiffLine?
    let language: SyntaxLanguage
    let gutterWidth: Int
    let columns: DiffColumns
    let sideWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            side(left, number: left?.oldLine, columns: columns.left)
            Divider().overlay(OpenPawTheme.lineStrong)
            side(right, number: right?.newLine, columns: columns.right)
        }
        .padding(.vertical, OpenPawTheme.Space.hair)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenLabel)
    }

    /// An absent side is a real fact — the change added or removed a line — so it renders as inert ground
    /// rather than as a gap the eye reads as misalignment.
    private func side(_ line: DiffLine?, number: UInt32?, columns: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            DiffGutterCell(value: number, width: gutterWidth)
            if let line {
                Text(DiffLineText.marker(for: line.kind))
                    .font(OpenPawTheme.Machine.code)
                    .foregroundStyle(DiffLineText.markerTone(for: line.kind))
                DiffCodeText(line: line, language: language, columns: columns)
            } else {
                // One extra column stands in for the +/− marker the other side prints.
                Text(DiffLineText.blank(columns: columns + 1))
                    .font(OpenPawTheme.Machine.code)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        // Each side takes half the pane, so the two columns fill the width evenly instead of collapsing to the
        // ideal width of their text and leaving the pane empty.
        .frame(minWidth: sideWidth, alignment: .leading)
        .background(line.map { DiffLineText.fill(for: $0.kind) } ?? OpenPawTheme.ink)
    }

    private var spokenLabel: String {
        switch (left, right) {
        case (let left?, _?) where left.kind == .context:
            "unchanged, \(left.text)"
        case (let left?, let right?):
            "was \(left.text), now \(right.text)"
        case (let left?, nil):
            "removed, \(left.text)"
        case (nil, let right?):
            "added, \(right.text)"
        case (nil, nil):
            "blank"
        }
    }
}

/// A single line of code, at its ideal width, never wrapped.
///
/// `fixedSize` and `lineLimit(1)` together are what make the horizontal scroll meaningful: without them a
/// narrow proposal makes `Text` reflow, and a line of source broken across four visual rows is unreadable and
/// destroys the alignment the monospaced grid exists to provide.
struct DiffCodeText: View {
    let line: DiffLine
    let language: SyntaxLanguage
    let columns: Int

    var body: some View {
        Text(DiffLineText.padded(line, language: language, columns: columns))
            .font(OpenPawTheme.Machine.code)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

struct DiffGutterCell: View {
    let value: UInt32?
    let width: Int

    var body: some View {
        Text(DiffLineText.gutter(value, width: width))
            .font(OpenPawTheme.Machine.codeSmall)
            .foregroundStyle(OpenPawTheme.diffGutter)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, OpenPawTheme.Space.tight)
            .accessibilityHidden(true)
    }
}

/// Text assembly for diff rows.
///
/// Every string is padded to the same character count, so the monospaced grid aligns and each row fill spans
/// the full width. That is why there is no pixel measurement anywhere in this file.
enum DiffLineText {

    static func marker(for kind: LineKind) -> String {
        switch kind {
        case .context: " "
        case .added: "+"
        case .removed: "−"
        case .noNewline: "\\"
        }
    }

    static func markerTone(for kind: LineKind) -> Color {
        switch kind {
        case .context: OpenPawTheme.textTertiary
        case .added: OpenPawTheme.diffAddedText
        case .removed: OpenPawTheme.diffRemovedText
        case .noNewline: OpenPawTheme.textTertiary
        }
    }

    static func fill(for kind: LineKind) -> Color {
        switch kind {
        case .context: OpenPawTheme.well
        case .added: OpenPawTheme.diffAddedFill
        case .removed: OpenPawTheme.diffRemovedFill
        case .noNewline: OpenPawTheme.panel
        }
    }

    /// Syntax colour first, then the padding, so highlighting sits under the diff fill instead of fighting it.
    static func padded(_ line: DiffLine, language: SyntaxLanguage, columns: Int) -> AttributedString {
        guard line.kind != .noNewline else {
            var marker = AttributedString("No newline at end of file")
            marker.foregroundColor = OpenPawTheme.textTertiary
            return marker
        }
        var attributed = SyntaxHighlighter.highlight(line.text, language: language)
        let deficit = columns - line.text.count
        if deficit > 0 {
            attributed.append(AttributedString(String(repeating: " ", count: deficit)))
        }
        return attributed
    }

    static func blank(columns: Int) -> String {
        String(repeating: " ", count: max(0, columns))
    }

    static func gutter(_ value: UInt32?, width: Int) -> String {
        guard let value else { return String(repeating: "·", count: width) }
        let digits = String(value)
        guard digits.count < width else { return digits }
        return String(repeating: " ", count: width - digits.count) + digits
    }

    /// VoiceOver hears what happened before it hears the code.
    static func spokenLabel(_ line: DiffLine) -> String {
        switch line.kind {
        case .context: "unchanged, \(line.text)"
        case .added: "added, \(line.text)"
        case .removed: "removed, \(line.text)"
        case .noNewline: "no newline at end of file"
        }
    }
}

// MARK: - Ref entry

struct DiffRefPrompt: Identifiable, Hashable {
    enum Kind: Hashable {
        case commit
        case range
    }

    let id = UUID()
    let kind: Kind
}

/// Commits and branch ranges are typed in, because the host exposes no ref-listing route and a picker over
/// invented refs would be a lie. Each field says what shape it wants.
struct DiffRefSheet: View {
    let prompt: DiffRefPrompt
    let onSubmit: (DiffMode) -> Void
    let onCancel: () -> Void

    @State private var commit = ""
    @State private var base = "main"
    @State private var head = "HEAD"

    var body: some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.large) {
            Text(prompt.kind == .commit ? "Compare a commit" : "Compare a branch range")
                .font(OpenPawTheme.Human.title)
                .foregroundStyle(OpenPawTheme.textPrimary)

            switch prompt.kind {
            case .commit:
                field("Commit", text: $commit, hint: "A sha, a tag, or HEAD~1")
            case .range:
                field("Base", text: $base, hint: "The branch you would merge into")
                field("Head", text: $head, hint: "The branch with the work on it")
            }

            HStack(spacing: OpenPawTheme.Space.medium) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .font(OpenPawTheme.Machine.body)
                    .foregroundStyle(OpenPawTheme.textSecondary)
                    .frame(minWidth: 44, minHeight: 44)
                Spacer()
                Button("Show diff") {
                    switch prompt.kind {
                    case .commit:
                        onSubmit(.commit(trim(commit)))
                    case .range:
                        onSubmit(.range(base: trim(base), head: trim(head)))
                    }
                }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
                .disabled(!isComplete)
            }
        }
        .padding(OpenPawTheme.Space.xl)
        .frame(minWidth: 320)
        .background(OpenPawTheme.panelWarm)
    }

    private var isComplete: Bool {
        switch prompt.kind {
        case .commit: !trim(commit).isEmpty
        case .range: !trim(base).isEmpty && !trim(head).isEmpty
        }
    }

    private func trim(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func field(_ label: String, text: Binding<String>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
            Text(label).microLabel()
            TextField(label, text: text)
                .textFieldStyle(.plain)
                .font(OpenPawTheme.Machine.body)
                .foregroundStyle(OpenPawTheme.textPrimary)
                .repoTextInput()
                .padding(OpenPawTheme.Space.small)
                .frame(minHeight: 44)
                .background(
                    RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card)
                        .fill(OpenPawTheme.well)
                )
            Text(hint)
                .font(OpenPawTheme.Human.caption)
                .foregroundStyle(OpenPawTheme.textTertiary)
        }
    }
}

// MARK: - Preview

#Preview("Diff viewer") {
    NavigationStack {
        DiffViewerView(
            model: PreviewBackend.model(.populated),
            repo: "openpaw",
            openInFileBrowser: { _ in }
        )
    }
}
