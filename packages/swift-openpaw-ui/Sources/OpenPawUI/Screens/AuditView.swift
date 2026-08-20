import Foundation
import OpenPawProtocol
import SwiftUI

/// The host's audit log: what each paired device asked for, and what the host did about it.
///
/// The log lives on the host, never on the phone, and this screen only reads it. Rows are monospaced because the
/// columns *are* the information — a time, a device, an action, a target and a result — but they wrap rather than
/// sit in fixed-width cells, so the screen still reads at the largest Dynamic Type sizes.
public struct AuditView: View {
    private let model: OpenPawModel
    private let limit: Int

    @State private var entries: [AuditEntry] = []
    @State private var isLoading = true

    public init(model: OpenPawModel, limit: Int = 200) {
        self.model = model
        self.limit = limit
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(OpenPawTheme.line)
            log
        }
        .background(OpenPawTheme.ink)
        .navigationTitle("Audit")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: OpenPawTheme.Space.medium) {
            HStack(spacing: OpenPawTheme.Space.small) {
                Text("entries").microLabel(OpenPawTheme.textSecondary)
                Text("\(entries.count)")
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
            .accessibilityLabel("\(entries.count) audit entries")

            Spacer(minLength: OpenPawTheme.Space.small)

            #if os(macOS)
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OpenPawTheme.textSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reload the audit log")
            #endif
        }
        .padding(.horizontal, OpenPawTheme.Space.large)
        .padding(.vertical, OpenPawTheme.Space.small)
    }

    // MARK: - Log

    private var log: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let error = model.lastError {
                    InlineErrorPanel(error: error) { model.lastError = nil }
                        .padding(.horizontal, OpenPawTheme.Space.large)
                        .padding(.top, OpenPawTheme.Space.medium)
                }
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(OpenPawTheme.ink)
        .refreshable { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && entries.isEmpty {
            WorkingIndicator(label: "Reading the audit log")
                .frame(maxWidth: .infinity)
                .padding(.vertical, OpenPawTheme.Space.section)
        } else if entries.isEmpty {
            emptyState
                .frame(maxWidth: .infinity)
                .padding(.horizontal, OpenPawTheme.Space.large)
                .padding(.vertical, OpenPawTheme.Space.section)
        } else {
            ForEach(days) { day in
                dayHeader(day)
                ForEach(day.entries) { entry in
                    AuditRow(entry: entry)
                    Divider()
                        .overlay(OpenPawTheme.line)
                        .padding(.leading, OpenPawTheme.Space.large)
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.backend == nil {
            EmptyStateView(
                glyph: "point.3.connected.trianglepath.dotted",
                title: "No host connected",
                message: "The audit log is written on the host, not on this device. Connect a host to read it."
            )
        } else {
            EmptyStateView(
                glyph: "list.bullet.rectangle.portrait",
                title: "Nothing recorded yet",
                message: "Every decision a device sends — approve, deny, stop — is written here with the device "
                    + "that sent it. Decide something in the Inbox and it shows up."
            )
        }
    }

    private func dayHeader(_ day: AuditDay) -> some View {
        HStack(spacing: OpenPawTheme.Space.small) {
            Text(day.label).microLabel(OpenPawTheme.textSecondary)
            Text("\(day.entries.count)")
                .font(OpenPawTheme.Machine.label)
                .monospacedDigit()
                .foregroundStyle(OpenPawTheme.textTertiary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, OpenPawTheme.Space.large)
        .padding(.top, OpenPawTheme.Space.large)
        .padding(.bottom, OpenPawTheme.Space.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Grouping

    /// Newest day first, newest entry first inside a day: an audit log is read backwards from what just happened.
    private var days: [AuditDay] {
        let calendar = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [AuditEntry]] = [:]
        for entry in entries.sorted(by: { $0.at > $1.at }) {
            let key = calendar.startOfDay(for: entry.at)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(entry)
        }
        return order.map { AuditDay(start: $0, entries: buckets[$0] ?? []) }
    }

    // MARK: - Loading

    private func load() async {
        guard let backend = model.backend else {
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            entries = try await backend.audit(limit: limit)
        } catch {
            model.present(error, while: "loading the audit log")
        }
    }
}

// MARK: - Row

private struct AuditRow: View {
    let entry: AuditEntry

    var body: some View {
        VStack(alignment: .leading, spacing: OpenPawTheme.Space.tight) {
            HStack(alignment: .firstTextBaseline, spacing: OpenPawTheme.Space.small) {
                Text(MachineTime.clock(entry.at))
                    .font(OpenPawTheme.Machine.code)
                    .monospacedDigit()
                    .foregroundStyle(OpenPawTheme.textSecondary)
                Text(entry.deviceID ?? "host")
                    .microLabel()
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: OpenPawTheme.Space.small)
                HStack(spacing: OpenPawTheme.Space.tight) {
                    Image(systemName: outcome.glyph)
                        .font(.system(size: 10, weight: .semibold))
                        .accessibilityHidden(true)
                    Text(entry.result)
                        .font(OpenPawTheme.Machine.codeSmall)
                        .lineLimit(1)
                }
                .foregroundStyle(outcome.color)
            }
            Text(entry.action)
                .font(OpenPawTheme.Machine.body)
                .foregroundStyle(OpenPawTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let target = entry.target, !target.isEmpty {
                Text(target)
                    .font(OpenPawTheme.Machine.codeSmall)
                    .foregroundStyle(OpenPawTheme.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, OpenPawTheme.Space.large)
        .padding(.vertical, OpenPawTheme.Space.medium)
        .frame(minHeight: 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var outcome: AuditOutcome {
        AuditOutcome.classify(entry.result)
    }

    private var accessibilityLabel: String {
        var parts = [MachineTime.clock(entry.at), entry.action]
        if let target = entry.target, !target.isEmpty { parts.append(target) }
        parts.append("\(outcome.word): \(entry.result)")
        parts.append("from \(entry.deviceID ?? "the host itself")")
        return parts.joined(separator: ". ")
    }
}

// MARK: - Outcome

/// The host writes `result` as its own free text, so the tint is derived while the literal string is always shown
/// beside it. The colour is a hint; the word is the fact.
private enum AuditOutcome {
    case allowed
    case refused
    case failed
    case other

    static func classify(_ result: String) -> AuditOutcome {
        let value = result.lowercased()
        if value.contains("error") || value.contains("fail") || value.contains("reject")
            || value.hasPrefix("4") || value.hasPrefix("5")
        {
            return .failed
        }
        if value.contains("deny") || value.contains("denied") || value.contains("stop")
            || value.contains("block")
        {
            return .refused
        }
        if value.contains("ok") || value.contains("approve") || value.contains("allow")
            || value.contains("accept") || value.hasPrefix("2")
        {
            return .allowed
        }
        return .other
    }

    var color: Color {
        switch self {
        case .allowed: OpenPawTheme.ok
        case .refused: OpenPawTheme.warn
        case .failed: OpenPawTheme.bad
        case .other: OpenPawTheme.textSecondary
        }
    }

    var glyph: String {
        switch self {
        case .allowed: "checkmark"
        case .refused: "hand.raised.slash"
        case .failed: "xmark.octagon"
        case .other: "circle"
        }
    }

    var word: String {
        switch self {
        case .allowed: "allowed"
        case .refused: "refused"
        case .failed: "failed"
        case .other: "recorded"
        }
    }
}

// MARK: - Day

private struct AuditDay: Identifiable {
    let start: Date
    let entries: [AuditEntry]

    var id: TimeInterval { start.timeIntervalSince1970 }

    var label: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(start) { return "today" }
        if calendar.isDateInYesterday(start) { return "yesterday" }
        return start.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

// MARK: - Previews

#Preview("Audit · populated") {
    NavigationStack {
        AuditView(model: PreviewBackend.model(.populated))
    }
}

#Preview("Audit · after a destructive request") {
    NavigationStack {
        AuditView(model: PreviewBackend.model(.reviewingDestructiveCommand))
    }
}

#Preview("Audit · nothing recorded") {
    NavigationStack {
        AuditView(model: PreviewBackend.model(.empty))
    }
}

#Preview("Audit · no host") {
    NavigationStack {
        AuditView(model: PreviewBackend.model(.disconnected))
    }
}
