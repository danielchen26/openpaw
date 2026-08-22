import Foundation
import OpenPawProtocol
import OpenPawTerminalCore
import SwiftUI

// MARK: - Layout

/// What a tap on a shortcut turns into once latched modifiers have been folded in.
public enum ShortcutBarAction: Sendable, Hashable {
    case send(KeyChord)
    case type(String)
    case latch(KeyModifiers)
}

/// Pure arrangement and resolution rules for the key bar.
///
/// The bar draws whatever is in the `ShortcutSet`; it holds no roster of its own. That is what makes the shortcut
/// editor and the shipped defaults the same mechanism instead of two lists that drift apart.
public struct ShortcutBarLayout: Sendable {
    /// Shortcut ids drawn as one joined cluster. Four separate floating arrow caps read as clutter, and a thumb
    /// expects to find them in the same place every time.
    public static let arrowIDs: [String] = ["left", "up", "down", "right"]

    public enum Item: Identifiable, Sendable, Hashable {
        case key(Shortcut)
        case cluster([Shortcut])

        public var id: String {
            switch self {
            case .key(let shortcut): shortcut.id
            case .cluster(let shortcuts): "cluster-" + shortcuts.map(\.id).joined(separator: "-")
            }
        }
    }

    /// Groups a set for display, collapsing the arrow keys into a cluster at the position of the first arrow.
    public static func items(for set: ShortcutSet) -> [Item] {
        let ordered = set.ordered()
        let arrows = arrowIDs.compactMap { id in ordered.first { $0.id == id } }
        var items: [Item] = []
        var clusterPlaced = false
        for shortcut in ordered {
            guard arrows.contains(where: { $0.id == shortcut.id }) else {
                items.append(.key(shortcut))
                continue
            }
            if !clusterPlaced {
                items.append(.cluster(arrows))
                clusterPlaced = true
            }
        }
        return items
    }

    /// Splits the bar across `count` rows. One row is a single scrolling strip; two rows break after the arrow
    /// cluster, which puts the keys a shell needs constantly on top and the navigation keys underneath.
    public static func rows(for set: ShortcutSet, count: Int) -> [[Item]] {
        let items = items(for: set)
        guard count > 1, let split = items.firstIndex(where: { if case .cluster = $0 { true } else { false } })
        else { return [items] }
        let head = Array(items[...split])
        let tail = Array(items[(split + 1)...])
        return tail.isEmpty ? [head] : [head, tail]
    }

    /// Folds the latched modifiers into a tap.
    ///
    /// Latching ctrl and then tapping a chord produces that chord *with* control; latching ctrl and tapping ctrl
    /// again just unlatches it. Command is never folded in: it does not exist on a PTY.
    public static func action(for shortcut: Shortcut, latched: KeyModifiers) -> ShortcutBarAction {
        switch shortcut.payload {
        case .modifierLatch(let modifiers):
            return .latch(modifiers)
        case .literal(let text):
            return .type(text)
        case .chord(let chord):
            var transmitted = latched
            transmitted.remove(.command)
            guard !transmitted.isEmpty else { return .send(chord) }
            return .send(KeyChord(chord.key, modifiers: chord.modifiers.union(transmitted)))
        }
    }

    /// True when this shortcut's latch is currently armed, so the cap can show it.
    public static func isLatched(_ shortcut: Shortcut, in latched: KeyModifiers) -> Bool {
        guard case .modifierLatch(let modifiers) = shortcut.payload, !modifiers.isEmpty else { return false }
        return latched.isSuperset(of: modifiers)
    }

    /// Spoken name for a cap. `esc` is not a word, and `^C` is not either.
    public static func voiceLabel(for shortcut: Shortcut) -> String {
        switch shortcut.payload {
        case .modifierLatch(let modifiers):
            return "\(modifiers.contains(.control) ? "Control" : "Option") modifier"
        case .literal(let text):
            return "\(shortcut.label), sends \(text.replacingOccurrences(of: "\n", with: " then return"))"
        case .chord(let chord):
            return spoken(chord)
        }
    }

    private static func spoken(_ chord: KeyChord) -> String {
        var parts: [String] = []
        if chord.modifiers.contains(.control) { parts.append("Control") }
        if chord.modifiers.contains(.alt) { parts.append("Option") }
        if chord.modifiers.contains(.shift) { parts.append("Shift") }
        switch chord.key {
        case .escape: parts.append("Escape")
        case .tab: parts.append("Tab")
        case .enter: parts.append("Return")
        case .backspace: parts.append("Backspace")
        case .delete: parts.append("Delete")
        case .space: parts.append("Space")
        case .up: parts.append("Up arrow")
        case .down: parts.append("Down arrow")
        case .left: parts.append("Left arrow")
        case .right: parts.append("Right arrow")
        case .home: parts.append("Home")
        case .end: parts.append("End")
        case .pageUp: parts.append("Page up")
        case .pageDown: parts.append("Page down")
        case .insert: parts.append("Insert")
        case .function(let number): parts.append("F\(number)")
        case .text(let value): parts.append(named(value))
        }
        return parts.joined(separator: " ")
    }

    private static func named(_ value: String) -> String {
        switch value {
        case "|": "Pipe"
        case "/": "Slash"
        case "\\": "Backslash"
        case "-": "Hyphen"
        case "~": "Tilde"
        default: value
        }
    }
}

// MARK: - Bar

/// The key toolbar that sits under the terminal: the keys a touch keyboard cannot produce, plus whatever the user
/// added.
///
/// Entirely machine register — monospaced caps, square corners, hairline dividers. A rounded key cap would read as
/// a button that does something clever; each of these does exactly one literal thing.
@MainActor
public struct ShortcutBarView: View {
    @Binding private var shortcuts: ShortcutSet
    @Binding private var latched: KeyModifiers
    private let rowCount: Int
    private let onChord: (KeyChord) -> Void
    private let onText: (String) -> Void

    @State private var isEditorPresented = false

    /// `rows` is 1 on a compact width, where the bar is a single scrolling strip, and 2 on a regular width, where
    /// there is room to keep the navigation keys permanently visible.
    public init(
        shortcuts: Binding<ShortcutSet>,
        latched: Binding<KeyModifiers>,
        rows: Int = 1,
        onChord: @escaping (KeyChord) -> Void,
        onText: @escaping (String) -> Void
    ) {
        _shortcuts = shortcuts
        _latched = latched
        self.rowCount = max(1, min(2, rows))
        self.onChord = onChord
        self.onText = onText
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.hairline) {
            ForEach(Array(ShortcutBarLayout.rows(for: shortcuts, count: rowCount).enumerated()), id: \.offset) {
                index, row in
                strip(row, showsEditButton: index == rowCount - 1)
            }
        }
        .background(OpenPawTheme.panel)
        .overlay(alignment: .top) {
            Rectangle().fill(OpenPawTheme.line).frame(height: OpenPawTheme.hairline)
        }
        .sheet(isPresented: $isEditorPresented) {
            NavigationStack {
                ShortcutEditorView(shortcuts: $shortcuts) { isEditorPresented = false }
            }
        }
        .accessibilityLabel("Terminal keys")
    }

    private func strip(_ items: [ShortcutBarLayout.Item], showsEditButton: Bool) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: OpenPawTheme.Space.tight) {
                ForEach(items) { item in
                    switch item {
                    case .key(let shortcut):
                        cap(shortcut)
                    case .cluster(let arrows):
                        cluster(arrows)
                    }
                }
                if showsEditButton {
                    editButton
                }
            }
            .padding(.horizontal, OpenPawTheme.Space.small)
            .padding(.vertical, OpenPawTheme.Space.tight)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Without an explicit anchor the strip can come up resting at its trailing end, which hides `esc` and
        // `ctrl` — the two keys the bar exists for. They stay put at the leading edge.
        .defaultScrollAnchor(.leading)
    }

    private func cluster(_ arrows: [Shortcut]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(arrows.enumerated()), id: \.element.id) { index, shortcut in
                if index > 0 {
                    Rectangle().fill(OpenPawTheme.line).frame(width: OpenPawTheme.hairline, height: 28)
                }
                cap(shortcut, isGrouped: true)
            }
        }
        .background(OpenPawTheme.well)
        .clipShape(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.machine, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.machine, style: .continuous).stroke(OpenPawTheme.line, lineWidth: OpenPawTheme.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Arrow keys")
    }

    private func cap(_ shortcut: Shortcut, isGrouped: Bool = false) -> some View {
        let engaged = ShortcutBarLayout.isLatched(shortcut, in: latched)
        return Button {
            press(shortcut)
        } label: {
            Text(shortcut.label)
                .font(OpenPawTheme.Machine.body)
                .lineLimit(1)
                .padding(.horizontal, OpenPawTheme.Space.small)
                // 44 in both directions, unconditionally. A key you miss is worse than a key you cannot see.
                .frame(minWidth: 44, minHeight: 44)
                .foregroundStyle(engaged ? OpenPawTheme.ink : OpenPawTheme.textPrimary)
                .background(background(engaged: engaged, isGrouped: isGrouped))
                // Clipped as well as stroked: a latched key fills its background, and an unclipped fill under a
                // rounded border shows square corners poking past the curve.
                .clipShape(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.machine, style: .continuous))
                .overlay {
                    if !isGrouped {
                        RoundedRectangle(cornerRadius: OpenPawTheme.Radius.machine, style: .continuous).stroke(
                            engaged ? OpenPawTheme.textPrimary : OpenPawTheme.line,
                            lineWidth: OpenPawTheme.hairline)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ShortcutBarLayout.voiceLabel(for: shortcut))
        .accessibilityValue(latchValue(shortcut, engaged: engaged))
        .accessibilityAddTraits(engaged ? [.isButton, .isSelected] : .isButton)
    }

    private func background(engaged: Bool, isGrouped: Bool) -> Color {
        if engaged { return OpenPawTheme.textPrimary }
        return isGrouped ? .clear : OpenPawTheme.well
    }

    private func latchValue(_ shortcut: Shortcut, engaged: Bool) -> String {
        guard case .modifierLatch = shortcut.payload else { return "" }
        return engaged ? "engaged" : "off"
    }

    private var editButton: some View {
        Button {
            isEditorPresented = true
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(OpenPawTheme.Machine.body)
                .frame(minWidth: 44, minHeight: 44)
                .foregroundStyle(OpenPawTheme.textSecondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Edit shortcuts")
    }

    private func press(_ shortcut: Shortcut) {
        switch ShortcutBarLayout.action(for: shortcut, latched: latched) {
        case .latch(let modifiers):
            if latched.isSuperset(of: modifiers) {
                latched.subtract(modifiers)
            } else {
                latched.formUnion(modifiers)
            }
        case .send(let chord):
            onChord(chord)
            // Sticky, not locking: one key press consumes the armed modifiers. Locking modifiers strand people in
            // a state they cannot see from across the room.
            latched = []
        case .type(let text):
            onText(text)
            latched = []
        }
    }
}

// MARK: - Custom shortcut editor

/// Edits the user-defined half of a `ShortcutSet`.
///
/// The set is Codable and is what gets persisted and exported, so what you build here is exactly what ships between
/// your devices. Built-in keys are listed but not editable: they are the ones a terminal cannot work without.
@MainActor
struct ShortcutEditorView: View {
    @Binding var shortcuts: ShortcutSet
    let onDone: () -> Void

    private var custom: [Shortcut] {
        shortcuts.ordered().filter { if case .literal = $0.payload { true } else { false } }
    }

    private var builtIn: [Shortcut] {
        shortcuts.ordered().filter { if case .literal = $0.payload { false } else { true } }
    }

    private var missingBuiltIns: [Shortcut] {
        ShortcutSet.default.shortcuts.filter { shortcuts[$0.id] == nil }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OpenPawTheme.Space.large) {
                HumanPanel {
                    VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
                        Text("Your own keys")
                            .font(OpenPawTheme.Human.title)
                            .foregroundStyle(OpenPawTheme.textPrimary)
                        Text(
                            """
                            A shortcut sends its text to the terminal exactly as typed. End it with a newline to \
                            run immediately, or leave the newline off to drop the command on the prompt for \
                            editing.
                            """
                        )
                        .font(OpenPawTheme.Human.prose)
                        .foregroundStyle(OpenPawTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if custom.isEmpty {
                    EmptyStateView(
                        glyph: "command",
                        title: "No shortcuts yet",
                        message: "Add the commands you type most. They appear at the end of the key bar.",
                        actionTitle: "Add shortcut",
                        action: add
                    )
                } else {
                    Panel(label: "Your keys") {
                        VStack(alignment: .leading, spacing: OpenPawTheme.Space.medium) {
                            ForEach(custom) { shortcut in
                                row(shortcut)
                            }
                            Button(action: add) {
                                Label("Add shortcut", systemImage: "plus")
                                    .font(OpenPawTheme.Machine.body)
                            }
                            .buttonStyle(.plain)
                            .frame(minHeight: 44)
                            .foregroundStyle(OpenPawTheme.textPrimary)
                        }
                    }
                }

                Panel(label: "Built in") {
                    VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
                        ShellWrap(spacing: OpenPawTheme.Space.small) {
                            ForEach(builtIn) { shortcut in
                                Text(shortcut.label)
                                    .font(OpenPawTheme.Machine.codeSmall)
                                    .padding(.horizontal, OpenPawTheme.Space.small)
                                    .padding(.vertical, OpenPawTheme.Space.hair)
                                    .foregroundStyle(OpenPawTheme.textSecondary)
                                    .background(OpenPawTheme.well)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: OpenPawTheme.Radius.machine, style: .continuous).stroke(OpenPawTheme.line, lineWidth: OpenPawTheme.hairline))
                            }
                        }
                        if missingBuiltIns.isEmpty {
                            Text("All shipped keys are present.")
                                .font(OpenPawTheme.Human.caption)
                                .foregroundStyle(OpenPawTheme.textTertiary)
                        } else {
                            Button(action: restoreBuiltIns) {
                                Text("Restore \(missingBuiltIns.count) missing key(s)")
                                    .font(OpenPawTheme.Machine.body)
                                    .frame(minHeight: 44)
                                    .foregroundStyle(OpenPawTheme.textPrimary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(OpenPawTheme.Space.large)
            .frame(maxWidth: 620, alignment: .leading)
        }
        .background(OpenPawTheme.ink)
        .navigationTitle("Shortcuts")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: onDone)
            }
        }
    }

    private func row(_ shortcut: Shortcut) -> some View {
        let position = custom.firstIndex { $0.id == shortcut.id } ?? 0
        return VStack(alignment: .leading, spacing: OpenPawTheme.Space.small) {
            HStack(spacing: OpenPawTheme.Space.small) {
                Text("key \(position + 1)").microLabel()
                Spacer(minLength: 0)
                Button {
                    move(shortcut, by: -1)
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(position == 0)
                .accessibilityLabel("Move \(shortcut.label) earlier")
                Button {
                    move(shortcut, by: 1)
                } label: {
                    Image(systemName: "arrow.down")
                }
                .disabled(position == custom.count - 1)
                .accessibilityLabel("Move \(shortcut.label) later")
                Button {
                    shortcuts.shortcuts.removeAll { $0.id == shortcut.id }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .accessibilityLabel("Remove \(shortcut.label)")
            }
            .buttonStyle(.plain)
            .font(OpenPawTheme.Machine.body)
            .foregroundStyle(OpenPawTheme.textSecondary)

            HStack(alignment: .top, spacing: OpenPawTheme.Space.small) {
                ShellField(label: "Cap", placeholder: "gst", text: labelBinding(shortcut.id))
                    .frame(maxWidth: 140)
                ShellField(label: "Sends", placeholder: "git status\\n", text: textBinding(shortcut.id))
            }
        }
        .padding(OpenPawTheme.Space.medium)
        .background(OpenPawTheme.well)
        .clipShape(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.machine, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: OpenPawTheme.Radius.machine, style: .continuous).stroke(OpenPawTheme.line, lineWidth: OpenPawTheme.hairline))
    }

    private func labelBinding(_ id: String) -> Binding<String> {
        Binding(
            get: { shortcuts[id]?.label ?? "" },
            set: { newValue in
                guard let index = shortcuts.shortcuts.firstIndex(where: { $0.id == id }) else { return }
                shortcuts.shortcuts[index].label = newValue
            }
        )
    }

    /// A real newline in a text field is invisible, so the field shows and accepts `\n` and stores the control
    /// character. Nothing else is escaped, because nothing else is invisible.
    private func textBinding(_ id: String) -> Binding<String> {
        Binding(
            get: {
                guard case .literal(let text) = shortcuts[id]?.payload else { return "" }
                return text.replacingOccurrences(of: "\n", with: "\\n")
            },
            set: { newValue in
                guard let index = shortcuts.shortcuts.firstIndex(where: { $0.id == id }) else { return }
                shortcuts.shortcuts[index].payload = .literal(
                    newValue.replacingOccurrences(of: "\\n", with: "\n"))
            }
        )
    }

    private func add() {
        let order = (shortcuts.shortcuts.map(\.order).max() ?? 0) + 1
        let id = "custom-\(UUID().uuidString.prefix(8).lowercased())"
        shortcuts.shortcuts.append(Shortcut(id: id, label: "new", payload: .literal(""), order: order))
    }

    private func restoreBuiltIns() {
        shortcuts.shortcuts.append(contentsOf: missingBuiltIns)
    }

    /// Reordering swaps `order` values, because `ordered()` sorts by `(order, id)` and that is the only field the
    /// persisted form uses for position.
    private func move(_ shortcut: Shortcut, by offset: Int) {
        let list = custom
        guard let position = list.firstIndex(where: { $0.id == shortcut.id }) else { return }
        let target = position + offset
        guard list.indices.contains(target) else { return }
        guard let a = shortcuts.shortcuts.firstIndex(where: { $0.id == list[position].id }),
            let b = shortcuts.shortcuts.firstIndex(where: { $0.id == list[target].id })
        else { return }
        let order = shortcuts.shortcuts[a].order
        shortcuts.shortcuts[a].order = shortcuts.shortcuts[b].order
        shortcuts.shortcuts[b].order = order
    }
}

// MARK: - Previews

private struct ShortcutBarPreviewHost: View {
    @State private var shortcuts = ShortcutSet(
        shortcuts: ShortcutSet.default.shortcuts + [
            Shortcut(id: "gst", label: "gst", payload: .literal("git status\n"), order: 100)
        ])
    @State private var latched: KeyModifiers = []
    let rows: Int

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Text(latched.contains(.control) ? "ctrl armed" : "no modifier")
                .font(OpenPawTheme.Machine.codeSmall)
                .foregroundStyle(OpenPawTheme.textTertiary)
            Spacer()
            ShortcutBarView(
                shortcuts: $shortcuts,
                latched: $latched,
                rows: rows,
                onChord: { _ in },
                onText: { _ in }
            )
        }
        .background(OpenPawTheme.ink)
    }
}

#Preview("Bar, one row") {
    ShortcutBarPreviewHost(rows: 1).preferredColorScheme(.dark)
}

#Preview("Bar, two rows") {
    ShortcutBarPreviewHost(rows: 2).preferredColorScheme(.dark)
}

#Preview("Shortcut editor") {
    @Previewable @State var shortcuts = OpenPawSettings.preview().shortcuts
    NavigationStack {
        ShortcutEditorView(shortcuts: $shortcuts) {}
    }
    .preferredColorScheme(.dark)
}
