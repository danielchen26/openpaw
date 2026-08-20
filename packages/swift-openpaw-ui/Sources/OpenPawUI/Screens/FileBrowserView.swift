import Observation
import OpenPawProtocol
import SwiftUI

// MARK: - Recent files

/// The handful of files a person keeps coming back to, per repository.
///
/// Persisted in `UserDefaults` because a recents list that forgets itself when the view is rebuilt is worse
/// than no recents list at all.
@Observable
public final class RecentFilesStore {
    public static let capacity = 12

    public private(set) var paths: [String]

    private let key: String
    private let defaults: UserDefaults

    public init(repo: String, defaults: UserDefaults = .standard) {
        self.key = "openpaw.recentFiles.\(repo)"
        self.defaults = defaults
        self.paths = defaults.stringArray(forKey: key) ?? []
    }

    /// Most recent first, no duplicates, capped.
    public func record(_ path: String) {
        var next = paths.filter { $0 != path }
        next.insert(path, at: 0)
        if next.count > Self.capacity { next.removeLast(next.count - Self.capacity) }
        paths = next
        defaults.set(next, forKey: key)
    }

    public func clear() {
        paths = []
        defaults.removeObject(forKey: key)
    }
}

// MARK: - Byte sizes

enum RepoBytes {
    /// Decimal units, because that is what every other tool in a developer's terminal prints.
    static func short(_ bytes: UInt64) -> String {
        let units = ["B", "kB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1000, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        if index == 0 { return "\(bytes) B" }
        return String(format: value < 10 ? "%.1f %@" : "%.0f %@", value, units[index])
    }
}

// MARK: - Tree rows

/// One visible row of the lazily expanded tree.
public struct FileTreeRow: Identifiable, Hashable, Sendable {
    public let entry: TreeEntry
    public let depth: Int

    public var id: String { entry.path }

    public init(entry: TreeEntry, depth: Int) {
        self.entry = entry
        self.depth = depth
    }
}

/// A run of matches inside one file.
public struct SearchGroup: Identifiable, Hashable, Sendable {
    public let path: String
    public let matches: [ContentMatch]

    public var id: String { path }

    public init(path: String, matches: [ContentMatch]) {
        self.path = path
        self.matches = matches
    }

    /// Groups in first-seen order, so the host's ranking survives the grouping.
    public static func group(_ matches: [ContentMatch]) -> [SearchGroup] {
        var order: [String] = []
        var byPath: [String: [ContentMatch]] = [:]
        for match in matches {
            if byPath[match.path] == nil { order.append(match.path) }
            byPath[match.path, default: []].append(match)
        }
        return order.map { SearchGroup(path: $0, matches: byPath[$0] ?? []) }
    }
}

enum TreeEntryCopy {

    static func glyph(_ entry: TreeEntry) -> String {
        if entry.isSymlink || entry.kind == .symlink { return "link" }
        switch entry.kind {
        case .directory: return "folder"
        case .file: return "doc.text"
        case .symlink: return "link"
        case .other: return "questionmark.square.dashed"
        }
    }

    static func word(_ entry: TreeEntry) -> String {
        if entry.isSymlink || entry.kind == .symlink { return "symlink" }
        switch entry.kind {
        case .directory: return "directory"
        case .file: return "file"
        case .symlink: return "symlink"
        case .other: return "special file"
        }
    }

    static func isSymlink(_ entry: TreeEntry) -> Bool {
        entry.isSymlink || entry.kind == .symlink
    }

    /// Directories first, then case-insensitive name order: the arrangement every file browser uses, because it
    /// puts structure above leaves.
    ///
    /// Lives here rather than on the view because sorting a tree is not a main-actor concern, and a comparator
    /// pinned to the main actor cannot be handed to `sorted(by:)` from anywhere else.
    static func order(_ lhs: TreeEntry, _ rhs: TreeEntry) -> Bool {
        let leftIsDirectory = lhs.kind == .directory
        let rightIsDirectory = rhs.kind == .directory
        if leftIsDirectory != rightIsDirectory { return leftIsDirectory }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    /// Only real files open. Directories expand, and everything else states why it does not.
    static func opens(_ entry: TreeEntry) -> Bool {
        entry.kind == .file && !isSymlink(entry)
    }
}

// MARK: - File browser

/// Read-only navigation of the repository as the host sees it, plus content search.
///
/// The tree is fetched one directory at a time. A monorepo has hundreds of thousands of files and asking for all
/// of them to draw twenty rows would be rude to the tunnel and slow for the reader.
public struct FileBrowserView: View {

    /// Files or content: two different questions, so two different fields.
    enum Lens: String, CaseIterable, Identifiable, Hashable {
        case files
        case search

        var id: String { rawValue }
        var title: String {
            switch self {
            case .files: "Files"
            case .search: "Search"
            }
        }
    }

    @Bindable private var model: OpenPawModel
    private let repo: String
    private let focusPath: String?
    private let sendPathToAgent: (String) -> Void

    @State private var recents: RecentFilesStore
    @State private var ref: String
    @State private var lens: Lens = .files
    @State private var nameFilter = ""
    @State private var query = ""
    @State private var searchResults: [SearchGroup]?
    @State private var isSearching = false
    @State private var children: [String: [TreeEntry]] = [:]
    @State private var expanded: Set<String> = []
    @State private var loading: Set<String> = []
    @State private var failure: String?
    @State private var highlightedPath: String?
    @State private var refPrompt = false

    public init(
        model: OpenPawModel,
        repo: String,
        ref: String = "HEAD",
        focusPath: String? = nil,
        sendPathToAgent: @escaping (String) -> Void
    ) {
        self._model = Bindable(model)
        self.repo = repo
        self.focusPath = focusPath
        self.sendPathToAgent = sendPathToAgent
        self._ref = State(initialValue: ref)
        self._recents = State(initialValue: RecentFilesStore(repo: repo))
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(OpenPawTheme.line)
            switch lens {
            case .files: filesLens
            case .search: searchLens
            }
        }
        .background(OpenPawTheme.ink)
        .navigationTitle(repo)
        .task(id: ref) { await loadRoot() }
        .navigationDestination(for: BlobRoute.self) { route in
            BlobView(
                model: model,
                repo: repo,
                ref: route.ref,
                path: route.path,
                focusLine: route.focusLine,
                sendPathToAgent: sendPathToAgent
            )
        }
        .sheet(isPresented: $refPrompt) {
            RefEntrySheet(
                title: "Browse another ref",
                hint: "A branch, a tag, or a commit sha",
                initial: ref
            ) { newRef in
                refPrompt = false
                guard !newRef.isEmpty else { return }
                ref = newRef
                children = [:]
                expanded = []
            } onCancel: {
                refPrompt = false
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
            HStack(spacing: OpenPawTheme.Space.medium) {
                refMenu
                Picker("View", selection: $lens) {
                    ForEach(Lens.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 190)
                .accessibilityLabel("Browsing \(lens.title)")
                Spacer(minLength: OpenPawTheme.Space.small)
            }
            field
        }
        .padding(.horizontal, OpenPawTheme.Space.large)
        .padding(.vertical, OpenPawTheme.Space.small)
    }

    private var refMenu: some View {
        Menu {
            Button("HEAD") { switchRef(to: "HEAD") }
            if let branch = model.repos.first(where: { $0.name == repo })?.branch, branch != "HEAD" {
                Button(branch) { switchRef(to: branch) }
            }
            Divider()
            Button("Other ref…") { refPrompt = true }
        } label: {
            HStack(spacing: OpenPawTheme.Space.tight) {
                Image(systemName: "arrow.triangle.branch")
                    .font(OpenPawTheme.Machine.codeSmall)
                Text(DiffModeCopy.shorten(ref))
                    .font(OpenPawTheme.Machine.headline)
            }
            .foregroundStyle(OpenPawTheme.textPrimary)
            .padding(.horizontal, OpenPawTheme.Space.small)
            .frame(minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card)
                    .fill(OpenPawTheme.panel)
            )
        }
        .accessibilityLabel("Ref, currently \(ref)")
    }

    @ViewBuilder private var field: some View {
        switch lens {
        case .files:
            RepoSearchField(
                glyph: "line.3.horizontal.decrease",
                prompt: "Filter loaded names",
                text: $nameFilter,
                onSubmit: nil
            )
        case .search:
            RepoSearchField(
                glyph: "magnifyingglass",
                prompt: "Search file contents",
                text: $query,
                onSubmit: { Task { await runSearch() } }
            )
        }
    }

    private func switchRef(to newRef: String) {
        guard newRef != ref else { return }
        ref = newRef
        children = [:]
        expanded = []
    }

    // MARK: Files

    @ViewBuilder private var filesLens: some View {
        if let failure {
            EmptyStateView(
                glyph: "exclamationmark.triangle",
                title: "The tree did not load",
                message: failure,
                actionTitle: "Try again"
            ) {
                Task { await loadRoot() }
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !recents.paths.isEmpty, nameFilter.isEmpty {
                        recentsSection
                    }
                    if nameFilter.isEmpty {
                        treeSection
                    } else {
                        filteredSection
                    }
                }
                .padding(.bottom, OpenPawTheme.Space.xl)
            }
        }
    }

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent").microLabel()
                Spacer()
                Button("Clear") { recents.clear() }
                    .buttonStyle(.plain)
                    .font(OpenPawTheme.Machine.label)
                    .foregroundStyle(OpenPawTheme.textTertiary)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .padding(.horizontal, OpenPawTheme.Space.large)

            ForEach(recents.paths, id: \.self) { path in
                NavigationLink(value: BlobRoute(path: path, ref: ref, focusLine: nil)) {
                    HStack(spacing: OpenPawTheme.Space.small) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(OpenPawTheme.Machine.codeSmall)
                            .foregroundStyle(OpenPawTheme.textTertiary)
                            .accessibilityHidden(true)
                        Text(path)
                            .font(OpenPawTheme.Machine.body)
                            .foregroundStyle(OpenPawTheme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, OpenPawTheme.Space.large)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded { recents.record(path) })
            }

            Divider().overlay(OpenPawTheme.line)
                .padding(.vertical, OpenPawTheme.Space.small)
        }
    }

    private var treeSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(RepoPath.lastSegment(repo)).microLabel()
                .padding(.horizontal, OpenPawTheme.Space.large)
                .padding(.bottom, OpenPawTheme.Space.tight)

            let rows = visibleRows()
            if rows.isEmpty && !loading.contains("") {
                EmptyStateView(
                    glyph: "folder",
                    title: "This ref has no files",
                    message: "\(DiffModeCopy.shorten(ref)) resolves to an empty tree. Pick another ref."
                )
            } else {
                ForEach(rows) { row in
                    treeRow(row)
                }
                if loading.contains("") {
                    loadingRow(depth: 0)
                }
            }
        }
    }

    @ViewBuilder private func treeRow(_ row: FileTreeRow) -> some View {
        let entry = row.entry
        if entry.kind == .directory && !TreeEntryCopy.isSymlink(entry) {
            Button {
                toggle(entry)
            } label: {
                FileEntryRow(
                    entry: entry,
                    depth: row.depth,
                    isExpanded: expanded.contains(entry.path),
                    isHighlighted: highlightedPath == entry.path
                )
            }
            .buttonStyle(.plain)
            .contextMenu { rowActions(for: entry.path) }
            .accessibilityAction(named: "Copy path") { OpenPawClipboard.copy(entry.path) }
            .accessibilityAction(named: "Send path to the agent") { sendPathToAgent(entry.path) }
            if loading.contains(entry.path) {
                loadingRow(depth: row.depth + 1)
            }
        } else if TreeEntryCopy.opens(entry) {
            NavigationLink(value: BlobRoute(path: entry.path, ref: ref, focusLine: nil)) {
                FileEntryRow(
                    entry: entry,
                    depth: row.depth,
                    isExpanded: false,
                    isHighlighted: highlightedPath == entry.path
                )
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded { recents.record(entry.path) })
            .contextMenu { rowActions(for: entry.path) }
            .accessibilityAction(named: "Copy path") { OpenPawClipboard.copy(entry.path) }
            .accessibilityAction(named: "Send path to the agent") { sendPathToAgent(entry.path) }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                FileEntryRow(
                    entry: entry,
                    depth: row.depth,
                    isExpanded: false,
                    isHighlighted: highlightedPath == entry.path
                )
                unreadableNote(for: entry, depth: row.depth)
            }
            .contextMenu { rowActions(for: entry.path) }
        }
    }

    /// The refusal is stated on the row, every time. A symlink out of the repository is exactly the shape of a
    /// path-traversal attempt, so hiding the entry would hide the fact that OpenPaw declined to follow it.
    @ViewBuilder private func unreadableNote(for entry: TreeEntry, depth: Int) -> some View {
        HStack(alignment: .top, spacing: OpenPawTheme.Space.tight) {
            Image(systemName: "hand.raised")
                .font(OpenPawTheme.Machine.codeSmall)
                .accessibilityHidden(true)
            Text(
                TreeEntryCopy.isSymlink(entry)
                    ? "OpenPaw will not read through this symlink. It reads only files inside the repository."
                    : "OpenPaw does not read this kind of entry. Only regular files are served."
            )
            .font(OpenPawTheme.Human.caption)
        }
        .foregroundStyle(OpenPawTheme.warn)
        .padding(.leading, indent(depth) + OpenPawTheme.Space.large)
        .padding(.trailing, OpenPawTheme.Space.large)
        .padding(.bottom, OpenPawTheme.Space.small)
    }

    @ViewBuilder private func rowActions(for path: String) -> some View {
        Button("Copy path") { OpenPawClipboard.copy(path) }
        Button("Send path to the agent") { sendPathToAgent(path) }
    }

    private func loadingRow(depth: Int) -> some View {
        HStack(spacing: OpenPawTheme.Space.small) {
            ProgressView().controlSize(.small)
            Text("Loading").microLabel()
        }
        .padding(.leading, indent(depth) + OpenPawTheme.Space.large)
        .frame(minHeight: 44, alignment: .leading)
        .accessibilityLabel("Loading directory contents")
    }

    private var filteredSection: some View {
        let needle = nameFilter.lowercased()
        let hits = children.values
            .flatMap { $0 }
            .filter { $0.name.lowercased().contains(needle) }
            .sorted { $0.path < $1.path }

        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Filtered").microLabel()
                Text("\(hits.count) of \(children.values.reduce(0) { $0 + $1.count }) loaded entries")
                    .font(OpenPawTheme.Machine.codeSmall)
                    .foregroundStyle(OpenPawTheme.textTertiary)
            }
            .padding(.horizontal, OpenPawTheme.Space.large)
            .padding(.bottom, OpenPawTheme.Space.tight)

            if hits.isEmpty {
                EmptyStateView(
                    glyph: "line.3.horizontal.decrease",
                    title: "No loaded name matches",
                    message: "The filter only sees directories you have already opened. "
                        + "Clear it, expand further, or switch to Search to look inside files."
                )
            } else {
                ForEach(hits) { entry in
                    treeRow(FileTreeRow(entry: entry, depth: 0))
                }
            }
        }
    }

    // MARK: Search

    @ViewBuilder private var searchLens: some View {
        if isSearching {
            EmptyStateView(
                glyph: "magnifyingglass",
                title: "Searching \(repo)",
                message: "The host is grepping the tree at \(DiffModeCopy.shorten(ref))."
            )
        } else if let searchResults {
            if searchResults.isEmpty {
                EmptyStateView(
                    glyph: "magnifyingglass",
                    title: "No file contains that",
                    message: "Nothing in \(repo) matches “\(query)”. Try a shorter fragment."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("Matches").microLabel()
                            Text("\(searchResults.reduce(0) { $0 + $1.matches.count }) in \(searchResults.count) files")
                                .font(OpenPawTheme.Machine.codeSmall)
                                .foregroundStyle(OpenPawTheme.textTertiary)
                        }
                        .padding(.horizontal, OpenPawTheme.Space.large)
                        .padding(.vertical, OpenPawTheme.Space.small)

                        ForEach(searchResults) { group in
                            SearchGroupSection(
                                group: group,
                                ref: ref,
                                onOpen: { recents.record(group.path) },
                                actions: { rowActions(for: group.path) }
                            )
                        }
                    }
                    .padding(.bottom, OpenPawTheme.Space.xl)
                }
            }
        } else {
            EmptyStateView(
                glyph: "text.magnifyingglass",
                title: "Search inside the files",
                message: "Type a fragment and press return. OpenPaw greps on the host, so the tree never "
                    + "crosses the tunnel."
            )
        }
    }

    // MARK: Layout helpers

    private func indent(_ depth: Int) -> CGFloat {
        CGFloat(depth) * OpenPawTheme.Space.large
    }

    /// Depth-first walk of what is loaded and expanded. Nothing recurses into a directory the reader has not
    /// opened, so this is bounded by what is on screen.
    private func visibleRows() -> [FileTreeRow] {
        var rows: [FileTreeRow] = []
        appendRows(of: "", depth: 0, into: &rows)
        return rows
    }

    private func appendRows(of path: String, depth: Int, into rows: inout [FileTreeRow]) {
        guard let entries = children[path] else { return }
        for entry in entries {
            rows.append(FileTreeRow(entry: entry, depth: depth))
            if entry.kind == .directory, expanded.contains(entry.path) {
                appendRows(of: entry.path, depth: depth + 1, into: &rows)
            }
        }
    }

    // MARK: Loading

    private func toggle(_ entry: TreeEntry) {
        if expanded.contains(entry.path) {
            expanded.remove(entry.path)
        } else {
            expanded.insert(entry.path)
            if children[entry.path] == nil {
                Task { await loadChildren(of: entry.path) }
            }
        }
    }

    private func loadRoot() async {
        failure = nil
        await loadChildren(of: "")
        if let focusPath {
            await reveal(focusPath)
        }
    }

    private func loadChildren(of path: String) async {
        guard let backend = model.backend else {
            failure = "No host is connected. Connect a host to browse its repositories."
            return
        }
        loading.insert(path)
        defer { loading.remove(path) }
        do {
            let entries = try await backend.tree(repo: repo, ref: ref, path: path)
            children[path] = entries.sorted(by: TreeEntryCopy.order)
        } catch {
            model.present(error, while: "listing \(path.isEmpty ? repo : path)")
            if path.isEmpty {
                failure = model.lastError?.detail ?? String(describing: error)
            }
        }
    }

    /// Opens every directory on the way to `path` so that `Open in file browser` lands on the row itself
    /// rather than at the root.
    private func reveal(_ path: String) async {
        var segments = path.split(separator: "/").map(String.init)
        guard segments.count > 1 else {
            highlightedPath = path
            return
        }
        segments.removeLast()
        var current = ""
        for segment in segments {
            current = RepoPath.join(current, segment)
            expanded.insert(current)
            if children[current] == nil {
                await loadChildren(of: current)
            }
        }
        highlightedPath = path
    }

    private func runSearch() async {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            searchResults = nil
            return
        }
        guard let backend = model.backend else {
            failure = "No host is connected. Connect a host to search its repositories."
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            let matches = try await backend.search(repo: repo, query: needle, path: nil)
            searchResults = SearchGroup.group(matches)
        } catch {
            model.present(error, while: "searching \(repo)")
            searchResults = []
        }
    }
}

/// Push target for a file.
struct BlobRoute: Hashable, Sendable {
    let path: String
    let ref: String
    let focusLine: Int?
}

// MARK: - Rows

struct FileEntryRow: View {
    let entry: TreeEntry
    let depth: Int
    let isExpanded: Bool
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: OpenPawTheme.Space.small) {
            if entry.kind == .directory && !TreeEntryCopy.isSymlink(entry) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(OpenPawTheme.Machine.codeSmall)
                    .foregroundStyle(OpenPawTheme.textTertiary)
                    .frame(width: OpenPawTheme.Space.medium)
                    .accessibilityHidden(true)
            } else {
                Spacer().frame(width: OpenPawTheme.Space.medium)
            }

            Image(systemName: TreeEntryCopy.glyph(entry))
                .font(OpenPawTheme.Machine.codeSmall)
                .foregroundStyle(
                    TreeEntryCopy.isSymlink(entry) ? OpenPawTheme.warn : OpenPawTheme.textSecondary
                )
                .accessibilityHidden(true)

            Text(entry.name)
                .font(OpenPawTheme.Machine.body)
                .foregroundStyle(OpenPawTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            if TreeEntryCopy.isSymlink(entry) {
                Text("symlink").microLabel(OpenPawTheme.warn)
            }

            Spacer(minLength: OpenPawTheme.Space.small)

            if entry.kind == .file, let size = entry.size {
                Text(RepoBytes.short(size))
                    .font(OpenPawTheme.Machine.codeSmall)
                    .foregroundStyle(OpenPawTheme.textTertiary)
            }
        }
        .padding(.leading, CGFloat(depth) * OpenPawTheme.Space.large + OpenPawTheme.Space.large)
        .padding(.trailing, OpenPawTheme.Space.large)
        .frame(minHeight: 44)
        .background(isHighlighted ? OpenPawTheme.well : Color.clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenLabel)
    }

    private var spokenLabel: String {
        var parts = ["\(TreeEntryCopy.word(entry)), \(entry.name)"]
        if entry.kind == .directory { parts.append(isExpanded ? "expanded" : "collapsed") }
        if let size = entry.size, entry.kind == .file { parts.append(RepoBytes.short(size)) }
        if TreeEntryCopy.isSymlink(entry) { parts.append("not followed") }
        return parts.joined(separator: ", ")
    }
}

struct SearchGroupSection<Actions: View>: View {
    let group: SearchGroup
    let ref: String
    let onOpen: () -> Void
    @ViewBuilder let actions: () -> Actions

    /// Widest line number in this file's hits, so one column serves every row in the group.
    private var numberWidth: Int {
        max(2, String(group.matches.map(\.line).max() ?? 1).count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: OpenPawTheme.Space.small) {
                Image(systemName: "doc.text")
                    .font(OpenPawTheme.Machine.codeSmall)
                    .foregroundStyle(OpenPawTheme.textSecondary)
                    .accessibilityHidden(true)
                Text(group.path)
                    .font(OpenPawTheme.Machine.headline)
                    .foregroundStyle(OpenPawTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: OpenPawTheme.Space.small)
                Text("\(group.matches.count)")
                    .font(OpenPawTheme.Machine.codeSmall)
                    .foregroundStyle(OpenPawTheme.textTertiary)
            }
            .padding(.horizontal, OpenPawTheme.Space.large)
            .frame(minHeight: 44)
            .background(OpenPawTheme.panel)
            .contextMenu { actions() }

            ForEach(group.matches) { match in
                NavigationLink(
                    value: BlobRoute(path: match.path, ref: ref, focusLine: Int(match.line))
                ) {
                    HStack(alignment: .firstTextBaseline, spacing: OpenPawTheme.Space.small) {
                        // Padded to a character count, like the diff gutter, so the column holds its shape at
                        // any Dynamic Type size instead of clipping against a fixed width.
                        Text(DiffLineText.gutter(match.line, width: numberWidth))
                            .font(OpenPawTheme.Machine.codeSmall)
                            .foregroundStyle(OpenPawTheme.diffGutter)
                        Text(match.text)
                            .font(OpenPawTheme.Machine.code)
                            .foregroundStyle(OpenPawTheme.textSecondary)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, OpenPawTheme.Space.large)
                    .padding(.vertical, OpenPawTheme.Space.small)
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded(onOpen))
                .accessibilityLabel("Line \(match.line), \(match.text)")
            }

            Divider().overlay(OpenPawTheme.line)
        }
    }
}

// MARK: - Fields and sheets

struct RepoSearchField: View {
    let glyph: String
    let prompt: String
    @Binding var text: String
    let onSubmit: (() -> Void)?

    var body: some View {
        HStack(spacing: OpenPawTheme.Space.small) {
            Image(systemName: glyph)
                .font(OpenPawTheme.Machine.codeSmall)
                .foregroundStyle(OpenPawTheme.textTertiary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(OpenPawTheme.Machine.body)
                .foregroundStyle(OpenPawTheme.textPrimary)
                .repoTextInput()
                .onSubmit { onSubmit?() }
            if !text.isEmpty {
                Button {
                    text = ""
                    onSubmit?()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(OpenPawTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Clear \(prompt.lowercased())")
            }
        }
        .padding(.horizontal, OpenPawTheme.Space.small)
        .frame(minHeight: 44)
        .background(
            RoundedRectangle(cornerRadius: OpenPawTheme.Radius.card)
                .fill(OpenPawTheme.well)
        )
    }
}

/// One field, because a ref is one string. The host has no ref-listing route, so this asks rather than guesses.
struct RefEntrySheet: View {
    let title: String
    let hint: String
    let initial: String
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var value: String

    init(
        title: String,
        hint: String,
        initial: String,
        onSubmit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.hint = hint
        self.initial = initial
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        self._value = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.large) {
            Text(title)
                .font(OpenPawTheme.Human.title)
                .foregroundStyle(OpenPawTheme.textPrimary)

            VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
                Text("Ref").microLabel()
                TextField("Ref", text: $value)
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

            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .font(OpenPawTheme.Machine.body)
                    .foregroundStyle(OpenPawTheme.textSecondary)
                    .frame(minWidth: 44, minHeight: 44)
                Spacer()
                Button("Browse") {
                    onSubmit(value.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
                .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(OpenPawTheme.Space.xl)
        .frame(minWidth: 320)
        .background(OpenPawTheme.panelWarm)
    }
}

// MARK: - Preview

#Preview("File browser") {
    NavigationStack {
        FileBrowserView(
            model: PreviewBackend.model(.populated),
            repo: "openpaw",
            sendPathToAgent: { _ in }
        )
    }
}
